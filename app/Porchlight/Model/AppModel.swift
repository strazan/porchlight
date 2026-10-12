import Foundation
import Observation
import PorchlightCore

struct LogLine: Identifiable {
    let id: Int
    let date: Date
    /// The server that wrote it, or nil for Porchlight's own messages.
    let server: String?
    let text: String
}

/// Everything the app's views show and do. The work is split by concern across the
/// `AppModel+…` files; stored state lives here, because Observation needs it in the class.
@MainActor @Observable
final class AppModel {
    enum State: Equatable {
        case off
        case starting
        case relay(RelayClient.Status)
    }

    // MARK: Settings

    var relayURL: String {
        didSet {
            defaults.set(relayURL, forKey: "relayURL")
            // A relay this Mac didn't set up may have apps connected that it knows nothing about.
            if relayURL != oldValue { defaults.set(true, forKey: "lockUnknownApps") }
        }
    }
    var secret: String {
        didSet {
            if !secrets.write(SecretAccount.relaySecret, secret) {
                log("Couldn't save the relay's secret in the Keychain: after Porchlight restarts, update the relay to connect again")
            }
        }
    }
    var keepAwake: Bool {
        didSet {
            defaults.set(keepAwake, forKey: "keepAwake")
            power.hold(keepAwake && isOn)
        }
    }
    /// Set once the app has deployed the relay itself.
    var deployment: Deployment? {
        didSet { saveDeployment() }
    }
    /// Client ID → the servers that app may use. Apps not listed may use all servers.
    var clientAccess: [String: Set<String>] = [:] {
        didSet {
            defaults.set(clientAccess.mapValues { Array($0).sorted() }, forKey: "clientAccess")
            syncRouter()
        }
    }

    // MARK: State

    var servers: [ServerConfig] = []
    var serverStatus: [String: UpstreamStatus] = [:]
    var state: State = .off
    /// Connections the relay has granted: one per connection, so an app can appear more than once.
    var clients: [PairedClient] = []
    /// Recent requests, oldest first.
    var activity: [ActivityEvent] = []
    var logs: [LogLine] = []
    /// Bumped when what apps see may have changed (servers, permissions, access), so tool
    /// counts reload.
    var toolsRevision = 0
    /// Settings opens on this tab next (e.g. "Set Up Porchlight…" opens the Relay tab).
    var requestedSettingsTab: SettingsView.Tab?
    @ObservationIgnored private(set) lazy var prompts = Prompts { [weak self] line in self?.log(line) }

    // MARK: Machinery

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let store: ServerStore
    @ObservationIgnored let secrets: any SecretStore
    /// Sample data for snapshots: no Keychain, relay, network or file copies.
    @ObservationIgnored let isSampleMode: Bool
    /// Icons for apps and servers.
    @ObservationIgnored let icons: IconStore
    /// The relay build that ships with this version of the app.
    @ObservationIgnored let bundledRelay = try? RelayBundle(bundle: .main)
    @ObservationIgnored var router: Router?
    @ObservationIgnored var client: RelayClient?
    @ObservationIgnored var runner: Task<Void, Never>?
    @ObservationIgnored var routerSync: Task<Void, Never>?
    @ObservationIgnored var shellEnvironment: [String: String]?
    @ObservationIgnored var catalogPush: Task<Void, Never>?
    /// The apps the relay has a catalog for, so ones that lose access can be forgotten.
    @ObservationIgnored var catalogClients: Set<String> = []
    @ObservationIgnored var queuedSummary: [(app: String, outcome: QueuedOutcome)] = []
    @ObservationIgnored var queuedNotice: Task<Void, Never>?
    @ObservationIgnored let power = PowerAssertion()
    @ObservationIgnored var connectivity: ConnectivityWatcher?
    @ObservationIgnored private(set) lazy var promptPanel = PromptPanel(model: self)
    @ObservationIgnored private var nextLogID = 0
    #if DEBUG
    @ObservationIgnored var sampleProbe: Result<ServerProbe.Report, ServerProbe.Failure>?
    @ObservationIgnored var sampleImportCandidates: [ImportCandidate] = []
    #endif

    static let maxActivity = 500
    static let maxLogLines = 2000
    /// More tools than this in one connector, and Settings suggests trimming them.
    static let manyTools = 40

    init(defaults: UserDefaults = .standard, store: ServerStore = .standard, sampleMode: Bool = false) {
        self.defaults = defaults
        self.store = store
        isSampleMode = sampleMode
        secrets = sampleMode ? MemorySecrets() : KeychainSecrets()
        icons = IconStore(defaults: defaults, sampleMode: sampleMode)
        relayURL = defaults.string(forKey: "relayURL") ?? ""
        secret = secrets.read(SecretAccount.relaySecret) ?? ""
        keepAwake = defaults.bool(forKey: "keepAwake")
        clientAccess = (defaults.dictionary(forKey: "clientAccess") as? [String: [String]] ?? [:]).mapValues(Set.init)
        deployment = loadDeployment()
        servers = loadServers()
        prompts.onChange = { [weak self] in self?.promptPanel.update() }
        guard !sampleMode else { return }
        connectivity = ConnectivityWatcher { [weak self] in self?.connectivityChanged() }
        if isConfigured { Task { await start() } }
    }

    // MARK: Derived state

    var isConfigured: Bool { !secret.isEmpty && hostURL != nil }
    /// Set up enough to show the connector and servers, rather than the getting-started steps.
    var isSetUp: Bool { isConfigured && !servers.isEmpty }
    var isOn: Bool { state != .off }
    var isConnected: Bool { state == .relay(.connected) }

    /// The URL to give apps for all servers combined.
    var endpoint: String { baseURL + "/mcp" }

    func endpoint(for server: ServerConfig) -> String { baseURL + "/mcp/\(server.name)" }

    private var baseURL: String {
        var base = relayURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// The relay's WebSocket endpoint for this Mac, derived from its public URL.
    var hostURL: URL? {
        guard var components = URLComponents(string: relayURL.trimmingCharacters(in: .whitespaces)) else { return nil }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        guard components.host != nil else { return nil }
        components.path = "/host"
        return components.url
    }

    func status(of server: ServerConfig) -> UpstreamStatus {
        serverStatus[server.name] ?? .idle
    }

    // MARK: Logs

    func log(_ text: String, server: String? = nil) {
        logs.append(LogLine(id: nextLogID, date: Date(), server: server, text: text))
        nextLogID += 1
        if logs.count > Self.maxLogLines { logs.removeFirst(logs.count - Self.maxLogLines) }
    }

    func clearLogs() {
        logs.removeAll()
    }

    func clearActivity() {
        activity.removeAll()
    }

    func recordActivity(_ event: ActivityEvent) {
        activity.append(event)
        if activity.count > Self.maxActivity { activity.removeFirst(activity.count - Self.maxActivity) }
    }
}
