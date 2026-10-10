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

@MainActor @Observable
final class AppModel {
    enum State: Equatable {
        case off
        case starting
        case relay(RelayClient.Status)
    }

    var relayURL: String { didSet { defaults.set(relayURL, forKey: "relayURL") } }
    var secret: String { didSet { Keychain.write("agentSecret", secret) } }

    private(set) var servers: [ServerConfig] = []
    private(set) var serverStatus: [String: StdioUpstream.Status] = [:]
    private(set) var state: State = .off
    private(set) var logs: [LogLine] = []
    /// Apps waiting for the owner to approve them, oldest first.
    private(set) var pendingPairings: [PairingRequest] = []
    /// Apps that have been granted access through the relay.
    private(set) var clients: [PairedClient] = []

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let store = ServerStore.standard
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var router: Router?
    @ObservationIgnored private var client: RelayClient?
    @ObservationIgnored private lazy var pairingPanel = PairingPanel(model: self)
    /// The relay forgets a pairing after this long (its consent page expires).
    private static let pairingLifetime: Duration = .seconds(10 * 60)
    @ObservationIgnored private var nextLogID = 0
    private static let maxLogLines = 2000

    init() {
        relayURL = defaults.string(forKey: "relayURL") ?? "http://localhost:8787"
        secret = Keychain.read("agentSecret") ?? ""
        servers = store.load() ?? migrateSingleServer()
        if isConfigured { Task { await start() } }
    }

    /// Before the server list existed, one server lived in two defaults keys.
    private func migrateSingleServer() -> [ServerConfig] {
        guard let name = defaults.string(forKey: "serverName"),
              let command = defaults.string(forKey: "serverCommand")
        else { return [] }
        var config = ServerConfig(name: ServerConfig.slug(name), command: "")
        config.commandLineString = command
        let migrated = config.command.isEmpty ? [] : [config]
        try? store.save(migrated)
        defaults.removeObject(forKey: "serverName")
        defaults.removeObject(forKey: "serverCommand")
        return migrated
    }

    // MARK: Derived state

    var isConfigured: Bool { !secret.isEmpty && agentURL != nil }
    var isOn: Bool { state != .off }
    var isConnected: Bool { state == .relay(.connected) }

    var statusText: String {
        switch state {
        case .off: "Off"
        case .starting, .relay(.connecting): "Connecting…"
        case .relay(.connected): "Connected"
        case .relay(.disconnected(let reason)): reason
        }
    }

    /// The URL to give MCP clients for all servers combined.
    var endpoint: String { baseURL + "/mcp" }

    func endpoint(for server: ServerConfig) -> String { baseURL + "/mcp/\(server.name)" }

    private var baseURL: String {
        var base = relayURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// The relay's WebSocket endpoint, derived from its public URL.
    var agentURL: URL? {
        guard var components = URLComponents(string: relayURL.trimmingCharacters(in: .whitespaces)) else { return nil }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        guard components.host != nil else { return nil }
        components.path = "/agent"
        return components.url
    }

    func status(of server: ServerConfig) -> StdioUpstream.Status {
        serverStatus[server.name] ?? .idle
    }

    // MARK: Servers

    func add(_ server: ServerConfig) {
        servers.append(server)
        serversChanged()
    }

    func update(_ server: ServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        serversChanged()
    }

    func remove(_ ids: Set<ServerConfig.ID>) {
        servers.removeAll { ids.contains($0.id) }
        serversChanged()
    }

    func setEnabled(_ enabled: Bool, for server: ServerConfig) {
        var changed = server
        changed.enabled = enabled
        update(changed)
    }

    /// Adds imported servers, renaming any whose name is taken.
    func importServers(_ configs: [ServerConfig]) {
        var taken = Set(servers.map(\.name))
        for var config in configs {
            config.name = ServerConfig.uniqueName(config.name, taken: taken)
            taken.insert(config.name)
            servers.append(config)
        }
        serversChanged()
    }

    /// True if a server with the same command is already in the list.
    func hasServer(like config: ServerConfig) -> Bool {
        servers.contains { $0.commandLine == config.commandLine && $0.env == config.env }
    }

    private func serversChanged() {
        do {
            try store.save(servers)
        } catch {
            log("Could not save servers: \(error.localizedDescription)")
        }
        let names = Set(servers.filter(\.enabled).map(\.name))
        serverStatus = serverStatus.filter { names.contains($0.key) }
        guard let router else { return }
        let servers = self.servers
        Task {
            await router.apply(servers)
            await router.warmUp()
        }
    }

    // MARK: Running

    func setOn(_ on: Bool) {
        if on { Task { await start() } } else { stop() }
    }

    func start() async {
        guard state == .off, let url = agentURL else { return }
        state = .starting
        log("Resolving shell environment…")
        let environment = await ShellEnvironment.resolve()
        guard state == .starting else { return } // switched off meanwhile

        let router = Router(
            environment: environment,
            log: { [weak self] server, line in
                Task { @MainActor in self?.log(line, server: server) }
            },
            onStatus: { [weak self] server, status in
                Task { @MainActor in self?.serverStatus[server] = status }
            }
        )
        await router.apply(servers)
        await router.warmUp()
        let client = RelayClient(
            url: url,
            secret: secret,
            handler: router,
            appVersion: "app-0.0.1",
            onStatus: { [weak self] status in
                Task { @MainActor in self?.relayStatusChanged(status) }
            },
            onEvent: { [weak self] event in
                Task { @MainActor in self?.relayEvent(event) }
            }
        )
        self.router = router
        self.client = client
        runner = Task { await client.run() }
        log("Connecting to \(relayURL)")
    }

    func stop() {
        runner?.cancel()
        runner = nil
        if let router { Task { await router.stopAll() } }
        router = nil
        client = nil
        serverStatus = [:]
        pendingPairings = []
        clients = []
        pairingPanel.update()
        if state != .off { log("Stopped") }
        state = .off
    }

    func restart() {
        stop()
        Task { await start() }
    }

    func clearLogs() {
        logs.removeAll()
    }

    // MARK: Pairing and clients

    func decide(_ request: PairingRequest, allow: Bool) {
        pendingPairings.removeAll { $0.id == request.id }
        pairingPanel.update()
        log("\(allow ? "Approved" : "Declined") \(request.clientName)")
        guard let client else { return }
        Task { await client.decidePairing(request.id, allow: allow) }
    }

    func revoke(_ paired: PairedClient) {
        log("Revoked \(paired.clientName)")
        guard let client else { return }
        Task { await client.revokeClient(paired.id) }
    }

    func showPendingPairing() {
        pairingPanel.update(bringToFront: true)
    }

    private func relayEvent(_ event: RelayEvent) {
        switch event {
        case .pairingRequested(let request):
            guard !pendingPairings.contains(where: { $0.id == request.id }) else { return }
            pendingPairings.append(request)
            log("\(request.clientName) wants to connect (code \(request.formattedCode))")
            pairingPanel.update(bringToFront: true)
            Task {
                try? await Task.sleep(for: Self.pairingLifetime)
                pendingPairings.removeAll { $0.id == request.id }
                pairingPanel.update()
            }
        case .clientsChanged(let clients):
            self.clients = clients.sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func relayStatusChanged(_ status: RelayClient.Status) {
        guard runner != nil else { return } // a late update after stop()
        state = .relay(status)
        switch status {
        case .connecting: break
        case .connected: log("Relay connected")
        case .disconnected(let reason): log("Relay disconnected: \(reason)")
        }
    }

    private func log(_ text: String, server: String? = nil) {
        logs.append(LogLine(id: nextLogID, date: Date(), server: server, text: text))
        nextLogID += 1
        if logs.count > Self.maxLogLines { logs.removeFirst(logs.count - Self.maxLogLines) }
    }
}
