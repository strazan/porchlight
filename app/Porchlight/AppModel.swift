import Foundation
import Observation
import PorchlightCore
import Security

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

    var relayURL: String {
        didSet {
            defaults.set(relayURL, forKey: "relayURL")
            // A relay this Mac didn't set up may have apps connected that it knows nothing about.
            if relayURL != oldValue { defaults.set(true, forKey: "lockUnknownApps") }
        }
    }
    var secret: String { didSet { if !isPreview { Keychain.write("relaySecret", secret) } } }
    var keepAwake: Bool {
        didSet {
            defaults.set(keepAwake, forKey: "keepAwake")
            power.hold(keepAwake && isOn)
        }
    }

    /// Set once the app has deployed the relay itself.
    private(set) var deployment: Deployment? {
        didSet { defaults.set(try? JSONEncoder().encode(deployment), forKey: "deployment") }
    }

    struct Deployment: Codable, Equatable {
        var accountID: String
        var accountName: String
        var scriptName: String
        /// The relay build that's deployed, from its bundle manifest.
        var relaySHA: String
    }

    /// The relay build that ships with this version of the app.
    @ObservationIgnored let bundledRelay = try? RelayBundle(bundle: .main)

    var relayUpdateAvailable: Bool {
        guard let deployment, let bundledRelay else { return false }
        return deployment.relaySHA != bundledRelay.sha256
    }

    private(set) var servers: [ServerConfig] = []
    private(set) var serverStatus: [String: UpstreamStatus] = [:]
    private(set) var state: State = .off
    private(set) var logs: [LogLine] = []
    /// Apps waiting for the owner to approve them, oldest first.
    private(set) var pendingPairings: [PairingRequest] = []
    /// Grants the relay has issued: one per connection, so an app can appear more than once.
    private(set) var clients: [PairedClient] = []

    /// An app with access, and its connections (e.g. one per connector it added).
    struct ConnectedApp: Identifiable {
        let connections: [PairedClient]
        var id: String { latest.clientID }
        var latest: PairedClient { connections[0] }
    }

    /// Apps with access, newest first. Grouped by client ID, which is also what access is set by.
    var apps: [ConnectedApp] {
        var order: [String] = []
        var byClient: [String: [PairedClient]] = [:]
        for client in clients {
            if byClient[client.clientID] == nil { order.append(client.clientID) }
            byClient[client.clientID, default: []].append(client)
        }
        return order.map { ConnectedApp(connections: byClient[$0]!) }
    }
    /// Client ID → the servers that app may use. Apps not listed may use all servers.
    private(set) var clientAccess: [String: Set<String>] = [:] {
        didSet {
            defaults.set(clientAccess.mapValues { Array($0).sorted() }, forKey: "clientAccess")
            pushClientAccess()
        }
    }
    /// Bumped when what apps see may have changed (servers, permissions, access), so tool
    /// counts reload.
    private(set) var toolsRevision = 0
    /// More tools than this in one connector, and Settings suggests trimming them.
    static let manyTools = 40

    /// Tool calls waiting for the owner to allow or deny them, oldest first.
    private(set) var pendingApprovals: [ToolApprovalRequest] = []

    enum Prompt {
        case pairing(PairingRequest)
        case approval(ToolApprovalRequest)

        var key: String {
            switch self {
            case .pairing(let request): "pairing:\(request.id)"
            case .approval(let request): "approval:\(request.id)"
            }
        }
    }

    /// The prompt on screen. Set by the panel as it shows one.
    var shownPrompt: String?

    /// What the prompt panel shows: the one already on screen until it's answered, so a new
    /// request (anyone can ask to connect) never takes its place under the owner's cursor.
    /// Otherwise pairings first.
    var currentPrompt: Prompt? {
        let pairings = pendingPairings.map(Prompt.pairing)
        let approvals = pendingApprovals.map(Prompt.approval)
        return (pairings + approvals).first { $0.key == shownPrompt } ?? pairings.first ?? approvals.first
    }
    /// Recent requests, oldest first.
    private(set) var activity: [ActivityEvent] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: ServerStore
    /// Sample data for snapshots and previews: no Keychain, relay or network.
    @ObservationIgnored let isPreview: Bool
    /// Icons for apps and servers.
    @ObservationIgnored let icons: IconStore
    @ObservationIgnored var previewProbe: Result<ServerProbe.Report, ServerProbe.Failure>?
    @ObservationIgnored var previewImportCandidates: [ImportCandidate] = []
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var catalogPush: Task<Void, Never>?
    /// The apps the relay has a catalog for, so ones that lose access can be forgotten.
    @ObservationIgnored private var catalogClients: Set<String> = []
    @ObservationIgnored private var queuedSummary: [(app: String, outcome: QueuedOutcome)] = []
    @ObservationIgnored private var queuedNotice: Task<Void, Never>?
    @ObservationIgnored private var router: Router?
    @ObservationIgnored private var shellEnvironment: [String: String]?
    @ObservationIgnored private var client: RelayClient?
    @ObservationIgnored private lazy var promptPanel = PromptPanel(model: self)
    @ObservationIgnored private var approvalWaiters: [UUID: CheckedContinuation<ToolApproval, Never>] = [:]
    /// Unanswered tool approvals are declined after this long.
    private static let approvalTimeout: Duration = .seconds(120)
    /// Requests saved while the Mac was offline have nobody waiting on them: ask for longer.
    private static let queuedApprovalTimeout: Duration = .seconds(24 * 3600)
    private static let maxActivity = 500
    @ObservationIgnored private let power = PowerAssertion()
    @ObservationIgnored private var connectivity: ConnectivityWatcher?
    /// The relay forgets a pairing after this long (its consent page expires).
    private static let pairingLifetime: Duration = .seconds(10 * 60)
    @ObservationIgnored private var nextLogID = 0
    private static let maxLogLines = 2000

    init(defaults: UserDefaults = .standard, store: ServerStore = .standard, preview: Bool = false) {
        self.defaults = defaults
        self.store = store
        isPreview = preview
        icons = IconStore(defaults: defaults, preview: preview)
        relayURL = defaults.string(forKey: "relayURL") ?? ""
        secret = preview ? "" : Keychain.read("relaySecret") ?? ""
        keepAwake = defaults.bool(forKey: "keepAwake")
        clientAccess = (defaults.dictionary(forKey: "clientAccess") as? [String: [String]] ?? [:]).mapValues(Set.init)
        deployment = defaults.data(forKey: "deployment").flatMap { try? JSONDecoder().decode(Deployment.self, from: $0) }
        var unreadable: Error?
        do {
            servers = try store.load() ?? []
        } catch {
            servers = []
            unreadable = error
        }
        if let unreadable { setAsideUnreadableServerList(unreadable) }
        guard !preview else { return }
        connectivity = ConnectivityWatcher { [weak self] in self?.connectivityChanged() }
        if isConfigured { Task { await start() } }
    }

    /// Keeps a server list that can't be read (say, edited by hand into invalid JSON) next to
    /// where it was, rather than saving over it, and starts with an empty one.
    private func setAsideUnreadableServerList(_ error: Error) {
        let aside = store.url.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: aside)
        do {
            try FileManager.default.moveItem(at: store.url, to: aside)
            log("Couldn't read the server list (\(error.localizedDescription)); it's kept as \(aside.lastPathComponent)")
        } catch {
            log("Couldn't read the server list or set it aside: \(error.localizedDescription)")
        }
    }

    // MARK: Derived state

    var isConfigured: Bool { !secret.isEmpty && hostURL != nil }
    /// Set up enough to show the connector and servers, rather than the getting-started steps.
    var isSetUp: Bool { isConfigured }
    /// Settings opens on this tab next (e.g. "Set Up Porchlight…" opens the Relay tab).
    var requestedSettingsTab: SettingsView.Tab?
    var isOn: Bool { state != .off }
    var isConnected: Bool { state == .relay(.connected) }

    var statusText: String {
        switch state {
        case .off: isConfigured ? "Off" : "Not set up yet"
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

    // MARK: Servers

    func add(_ server: ServerConfig) {
        servers.append(server)
        serversChanged()
    }

    func update(_ server: ServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        let oldName = servers[index].name
        servers[index] = server
        if oldName != server.name {
            // Apps limited to this server keep access under its new name.
            clientAccess = clientAccess.mapValues { names in
                names.contains(oldName) ? names.subtracting([oldName]).union([server.name]) : names
            }
        }
        serversChanged()
    }

    func remove(_ ids: Set<ServerConfig.ID>) {
        let removed = Set(servers.filter { ids.contains($0.id) }.map(\.name))
        servers.removeAll { ids.contains($0.id) }
        clientAccess = clientAccess.mapValues { $0.subtracting(removed) }
        serversChanged()
    }

    func setEnabled(_ enabled: Bool, for server: ServerConfig) {
        var changed = server
        changed.enabled = enabled
        update(changed)
    }

    /// Adds imported servers, renaming any whose name is taken.
    /// Imports the chosen candidates, first copying any Claude Desktop extensions' files.
    func importServers(from candidates: [ImportCandidate]) {
        importServers(candidates.compactMap { candidate in
            guard !isPreview else { return candidate.config }
            do {
                try ConfigImporter.install(candidate)
                return candidate.config
            } catch {
                log("Could not copy \(candidate.originalName): \(error.localizedDescription)")
                return nil
            }
        })
    }

    func importServers(_ configs: [ServerConfig]) {
        var taken = Set(servers.map(\.name))
        for var config in configs {
            config.name = ServerConfig.uniqueName(config.name, taken: taken)
            taken.insert(config.name)
            servers.append(config)
        }
        serversChanged()
    }

    /// Tries a config the way a client would, for the editor's Test Connection.
    func probe(_ config: ServerConfig) async -> Result<ServerProbe.Report, ServerProbe.Failure> {
        if let previewProbe { return previewProbe }
        if shellEnvironment == nil, config.transport == .stdio { shellEnvironment = await ShellEnvironment.resolve() }
        return await ServerProbe.run(config, environment: shellEnvironment ?? ProcessInfo.processInfo.environment)
    }

    /// Servers configured in Claude Desktop (and its extensions), Claude Code and Cursor.
    func importCandidates() -> [ImportCandidate] {
        isPreview ? previewImportCandidates : ConfigImporter.candidates()
    }

    /// The Cloudflare token saved by an earlier deploy.
    func savedCloudflareToken() -> String {
        isPreview ? "" : Keychain.read("cloudflareToken") ?? ""
    }

    /// True if a server with the same command is already in the list.
    func hasServer(like config: ServerConfig) -> Bool {
        servers.contains { $0.sameServer(as: config) }
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
            scheduleCatalogPush()
            toolsRevision += 1
        }
    }

    /// How many tools an app sees in one connector (nil: one that may use every server).
    /// Nil while Porchlight is off.
    func toolCount(for clientID: String?) async -> Int? {
        if isPreview { return clientID.flatMap { clientAccess[$0] } == nil ? 33 : 20 }
        guard let router else { return nil }
        return await router.toolCount(for: clientID ?? "")
    }

    // MARK: Running

    func setOn(_ on: Bool) {
        if on { Task { await start() } } else { stop() }
    }

    func start() async {
        guard state == .off, let url = hostURL else { return }
        state = .starting
        log("Resolving shell environment…")
        let environment = await ShellEnvironment.resolve()
        shellEnvironment = environment
        guard state == .starting else { return } // switched off meanwhile

        let router = Router(
            environment: environment,
            log: { [weak self] server, line in
                Task { @MainActor in self?.log(line, server: server) }
            },
            onStatus: { [weak self] server, status in
                Task { @MainActor in self?.serverStatus[server] = status }
            },
            approve: { [weak self] request in
                await self?.requestApproval(request) ?? .deny
            },
            onActivity: { [weak self] event in
                Task { @MainActor in self?.recordActivity(event) }
            }
        )
        await router.apply(servers)
        await router.setClientAccess(clientAccess)
        await router.warmUp()
        let client = RelayClient(
            url: url,
            secret: secret,
            handler: router,
            appVersion: "app-\(Porchlight.version)",
            queueKey: Self.queueKey(),
            ledger: QueueLedger(file: Self.supportDirectory.appending(path: "queue-finished.json")),
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
        power.hold(keepAwake)
        log("Connecting to \(relayURL)")
    }

    func stop() {
        runner?.cancel()
        runner = nil
        catalogPush?.cancel()
        catalogClients = []
        if let router { Task { await router.stopAll() } }
        router = nil
        client = nil
        serverStatus = [:]
        pendingPairings = []
        clients = []
        for request in pendingApprovals { answer(request, with: .deny) }
        promptPanel.update()
        power.hold(false)
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

    private func connectivityChanged() {
        guard let client else { return }
        log("Network changed or Mac woke up; reconnecting")
        Task { await client.reconnectNow() }
    }

    // MARK: Deploying the relay

    /// Deploys the relay to a Cloudflare account and connects to it. A first deploy gets a
    /// fresh secret; redeploying to the same place keeps the current one.
    func deploy(
        token: String,
        account: CloudflareAPI.Account,
        progress: @escaping @Sendable (RelayDeployer.Step) -> Void
    ) async throws -> URL {
        guard let bundledRelay else { throw DeployError.bundleMissing }
        let sameTarget = deployment?.accountID == account.id
        let hostSecret = sameTarget && !secret.isEmpty ? secret : Self.newSecret()
        let scriptName = deployment?.scriptName ?? RelayDeployer.defaultScriptName
        let deployer = RelayDeployer(api: CloudflareAPI(token: token), bundle: bundledRelay)
        log("Deploying the relay to \(account.name)…")
        let url = try await deployer.deploy(account: account.id, scriptName: scriptName, hostSecret: hostSecret, progress: progress)

        Keychain.write("cloudflareToken", token)
        deployment = Deployment(accountID: account.id, accountName: account.name, scriptName: scriptName, relaySHA: bundledRelay.sha256)
        relayURL = url.absoluteString
        if hostSecret != secret { secret = hostSecret }
        if !isPreview, Keychain.read("relaySecret") != hostSecret {
            log("Couldn't save the relay's secret in the Keychain: after Porchlight restarts, update the relay to connect again")
        }
        log("Relay deployed at \(url.absoluteString)")
        restart()
        return url
    }

    /// Redeploys the relay that ships with this app, with the saved token.
    func updateRelay(progress: @escaping @Sendable (RelayDeployer.Step) -> Void) async throws {
        guard let deployment, let token = Keychain.read("cloudflareToken") else { throw UpdateError.notDeployedByApp }
        _ = try await deploy(token: token, account: .init(id: deployment.accountID, name: deployment.accountName), progress: progress)
    }

    enum UpdateError: LocalizedError {
        case notDeployedByApp

        var errorDescription: String? { "Deploy the relay from Porchlight first." }
    }

    static func newSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("No secure random bytes available")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Tool approvals and activity

    private func requestApproval(_ request: ToolApprovalRequest) async -> ToolApproval {
        await withCheckedContinuation { continuation in
            approvalWaiters[request.id] = continuation
            pendingApprovals.append(request)
            log("\(request.client.name) wants to run \(request.tool) on \(request.server)")
            promptPanel.update()
            Task {
                try? await Task.sleep(for: request.queuedAt == nil ? Self.approvalTimeout : Self.queuedApprovalTimeout)
                if approvalWaiters[request.id] != nil {
                    log("No answer about \(request.tool) in time; declined")
                    answer(request, with: .deny)
                }
            }
        }
    }

    func answer(_ request: ToolApprovalRequest, with approval: ToolApproval) {
        guard let waiter = approvalWaiters.removeValue(forKey: request.id) else { return }
        pendingApprovals.removeAll { $0.id == request.id }
        if approval == .allowAlways, var server = servers.first(where: { $0.name == request.server }) {
            server.toolPolicy.overrides[request.tool] = .allow
            update(server)
            log("Always allowing \(request.tool) on \(request.server)")
        }
        waiter.resume(returning: approval)
        promptPanel.update()
    }

    func showPendingPrompt() {
        promptPanel.update(focus: true)
    }

    private func recordActivity(_ event: ActivityEvent) {
        activity.append(event)
        if activity.count > Self.maxActivity { activity.removeFirst(activity.count - Self.maxActivity) }
    }

    func clearActivity() {
        activity.removeAll()
    }

    // MARK: Pairing and clients

    /// `servers`: when allowing, the servers the app may use, or nil for all of them.
    func decide(_ request: PairingRequest, allow: Bool, servers: Set<String>? = nil) {
        pendingPairings.removeAll { $0.id == request.id }
        if allow, !request.clientID.isEmpty {
            setAccess(clientID: request.clientID, servers: servers)
            // Where its access goes is a good place to find its icon (an app on this Mac isn't).
            if let website = request.clientDomain ?? (request.loopback ? nil : request.redirectHost) {
                icons.learnWebsite(website, for: IconStore.key(app: request.clientID))
            }
        }
        promptPanel.update()
        log("\(allow ? "Approved" : "Declined") \(request.clientName)")
        guard let client else { return }
        Task { await client.decidePairing(request.id, allow: allow) }
    }

    /// Where an app's icon comes from unless overridden: its verified domain.
    func defaultIconWebsite(forApp clientID: String) -> String? {
        clients.first { $0.clientID == clientID }?.clientDomain
    }

    /// Revokes every connection the app has.
    func revoke(_ app: ConnectedApp) {
        log("Revoked \(app.latest.clientName)")
        // No servers rather than no setting (which means all), in case a connection outlives
        // the revoke. Approving the app again sets its access afresh.
        clientAccess[app.id] = []
        guard let client else { return }
        let grants = app.connections.map(\.id)
        Task { for grant in grants { await client.revokeClient(grant) } }
    }

    /// After switching to another relay (or deploying from a new Mac), apps connected before
    /// have no access settings here, which would mean all servers. They start with none.
    private func lockUnknownApps() {
        guard defaults.bool(forKey: "lockUnknownApps") else { return }
        defaults.set(false, forKey: "lockUnknownApps")
        let unknown = Set(clients.map(\.clientID)).subtracting(clientAccess.keys)
        guard !unknown.isEmpty else { return }
        for clientID in unknown { clientAccess[clientID] = [] }
        log("\(unknown.count) app(s) connected to this relay before can't use any servers until you choose in Settings → Apps")
    }

    /// Asks the relay for the current list of apps.
    func refreshClients() {
        guard let client else { return }
        Task { await client.refreshClients() }
    }

    /// The servers an app may use, or nil if it may use all of them.
    func access(for clientID: String) -> Set<String>? {
        clientAccess[clientID]
    }

    func setAccess(clientID: String, servers: Set<String>?) {
        clientAccess[clientID] = servers
    }

    private func pushClientAccess() {
        guard let router else { return }
        let access = clientAccess
        Task {
            await router.setClientAccess(access)
            scheduleCatalogPush()
            toolsRevision += 1
        }
    }

    // MARK: Offline queue

    /// The key the relay seals requests to while the Mac is offline, made once and kept in
    /// the Keychain. (Losing it only loses what's queued at the time.)
    private static func queueKey() -> QueueKey {
        if let saved = Keychain.read("queueKey").flatMap({ Data(base64Encoded: $0) }),
           let key = try? QueueKey(rawRepresentation: saved) {
            return key
        }
        let key = QueueKey()
        Keychain.write("queueKey", key.rawRepresentation.base64EncodedString())
        return key
    }

    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Porchlight")
    }

    /// Tells the relay, for each app, what it sees and may queue while the Mac is offline.
    /// Debounced: servers, permissions and access often change several times in a row.
    private func scheduleCatalogPush() {
        guard let router, let client, case .relay(.connected) = state else { return }
        let current = Set(clients.map(\.clientID)).subtracting([""])
        let gone = catalogClients.subtracting(current)
        catalogPush?.cancel()
        catalogPush = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            for id in gone { await client.sendOfflineCatalog(clientID: id, catalog: nil) }
            for id in current.sorted() {
                let catalog = await router.offlineCatalog(for: id)
                guard !Task.isCancelled else { return }
                await client.sendOfflineCatalog(clientID: id, catalog: catalog)
            }
            catalogClients = current
        }
    }

    private func queuedFinished(_ item: QueuedRequest, _ outcome: QueuedOutcome) {
        let age = item.queuedAt.formatted(.relative(presentation: .named))
        switch outcome {
        case .ran: log("Ran a request \(item.clientName) made \(age), while the Mac was offline")
        case .failed: log("A request \(item.clientName) made \(age), while the Mac was offline, didn't go through")
        case .unreadable: log("Couldn't read a request \(item.clientName) made \(age) (sealed to an earlier key); skipped")
        }
        queuedSummary.append((item.clientName, outcome))
        queuedNotice?.cancel()
        queuedNotice = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            let summary = queuedSummary
            queuedSummary = []
            QueuedNotice.post(summary)
        }
    }

    private func relayEvent(_ event: RelayEvent) {
        switch event {
        case .pairingRequested(let request):
            guard !pendingPairings.contains(where: { $0.id == request.id }) else { return }
            // Anyone can ask to connect, so nothing is fetched for a request (like its icon)
            // until it's approved.
            pendingPairings.append(request)
            log("\(request.clientName) wants to connect (code \(request.formattedCode))")
            promptPanel.update()
            Task {
                try? await Task.sleep(for: Self.pairingLifetime)
                pendingPairings.removeAll { $0.id == request.id }
                promptPanel.update()
            }
        case .clientsChanged(let clients):
            self.clients = clients.sorted { $0.createdAt > $1.createdAt }
            lockUnknownApps()
            scheduleCatalogPush()
        case .queuedFinished(let item, let outcome):
            queuedFinished(item, outcome)
        }
    }

    private func relayStatusChanged(_ status: RelayClient.Status) {
        guard runner != nil else { return } // a late update after stop()
        state = .relay(status)
        switch status {
        case .connecting: break
        case .connected:
            log("Relay connected")
            scheduleCatalogPush()
            toolsRevision += 1
        case .disconnected(let reason): log("Relay disconnected: \(reason)")
        }
    }

    private func log(_ text: String, server: String? = nil) {
        logs.append(LogLine(id: nextLogID, date: Date(), server: server, text: text))
        nextLogID += 1
        if logs.count > Self.maxLogLines { logs.removeFirst(logs.count - Self.maxLogLines) }
    }

    // MARK: Sample data

    #if DEBUG
    enum SampleScenario {
        /// Connected, with servers, apps and activity.
        case everything
        /// Nothing set up yet.
        case firstRun
        case waitingForToolApproval
        case waitingForPairing
        /// Set up, but turned off.
        case switchedOff
    }

    func loadSampleData(_ scenario: SampleScenario) {
        precondition(isPreview, "sample data is only for previews")
        guard scenario != .firstRun else { return }
        relayURL = "https://porchlight-relay.you.workers.dev"
        secret = "sample-secret"
        state = .relay(.connected)
        deployment = Deployment(accountID: "a1", accountName: "Personal", scriptName: "porchlight-relay", relaySHA: bundledRelay?.sha256 ?? "")

        var obsidian = ServerConfig(name: "obsidian", url: "http://127.0.0.1:27123/mcp/", headers: ["Authorization": "Bearer 0123456789abcdef"])
        obsidian.toolPolicy.overrides = ["search": .allow, "delete_note": .deny]
        servers = [
            obsidian,
            ServerConfig(name: "filesystem", command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/Users/you/Documents"]),
            ServerConfig(name: "home-assistant", url: "http://homeassistant.local:8123/api/mcp", headers: ["Authorization": "Bearer 0123456789abcdef"]),
            ServerConfig(
                name: "apple-reminders", command: "node",
                args: ["/Users/you/Library/Application Support/Porchlight/Extensions/local.mcpb.high5-ventures-gmbh.apple-reminders/server/index.js"],
                env: ["REMINDERS_BINARY": "/Users/you/Library/Application Support/Porchlight/Extensions/local.mcpb.high5-ventures-gmbh.apple-reminders/bin/reminders-eventkit"]
            ),
            ServerConfig(name: "playwright", command: "npx", args: ["@playwright/mcp@latest"], enabled: false),
        ]
        serverStatus = ["obsidian": .running, "filesystem": .running, "home-assistant": .running, "apple-reminders": .running]

        let now = Date()
        clients = [
            PairedClient(id: "g1", clientID: "https://claude.ai/oauth/mcp-oauth-client-metadata", clientName: "Claude", clientDomain: "claude.ai", createdAt: now.addingTimeInterval(-3 * 86400)),
            PairedClient(id: "g2", clientID: "dcr-7f3a", clientName: "ChatGPT", clientDomain: nil, createdAt: now.addingTimeInterval(-2 * 3600)),
        ]
        clientAccess = ["dcr-7f3a": ["obsidian"]]
        // As a real pairing would: where its access went is where its icon comes from.
        icons.learnWebsite("chatgpt.com", for: IconStore.key(app: "dcr-7f3a"))

        let claude = ClientIdentity(id: "https://claude.ai/oauth/mcp-oauth-client-metadata", name: "Claude")
        let chatgpt = ClientIdentity(id: "dcr-7f3a", name: "ChatGPT")
        activity = [
            ActivityEvent(date: now.addingTimeInterval(-600), client: claude, server: nil, method: "tools/list", tool: nil, duration: .milliseconds(184), outcome: .ok),
            ActivityEvent(date: now.addingTimeInterval(-540), client: claude, server: "obsidian", method: "tools/call", tool: "search", duration: .milliseconds(92), outcome: .ok),
            ActivityEvent(date: now.addingTimeInterval(-500), client: claude, server: "filesystem", method: "tools/call", tool: "read_text_file", duration: .milliseconds(31), outcome: .ok),
            ActivityEvent(date: now.addingTimeInterval(-420), client: claude, server: "filesystem", method: "tools/call", tool: "write_file", duration: .seconds(6), outcome: .denied("The user declined this call to write_file on their Mac.")),
            ActivityEvent(date: now.addingTimeInterval(-300), client: chatgpt, server: "obsidian", method: "tools/call", tool: "get_note", duration: .milliseconds(140), outcome: .ok),
            ActivityEvent(date: now.addingTimeInterval(-240), client: claude, server: "apple-reminders", method: "tools/call", tool: "get_today", duration: .milliseconds(48), outcome: .ok),
            ActivityEvent(date: now.addingTimeInterval(-120), client: claude, server: "home-assistant", method: "tools/call", tool: "GetLiveContext", duration: .seconds(15), outcome: .error("home-assistant didn't answer in time")),
        ]
        for (index, line) in [
            (nil, "Connecting to https://porchlight-relay.you.workers.dev"),
            (nil, "Relay connected"),
            ("obsidian", "connected to http://127.0.0.1:27123/mcp/"),
            ("filesystem", "started: npx -y @modelcontextprotocol/server-filesystem /Users/you/Documents"),
            ("filesystem", "Secure MCP Filesystem Server running on stdio"),
            ("home-assistant", "connected to http://homeassistant.local:8123/api/mcp"),
            ("apple-reminders", "started: node …/apple-reminders/server/index.js"),
        ].enumerated() {
            logs.append(LogLine(id: index, date: now.addingTimeInterval(Double(index - 20)), server: line.0, text: line.1))
        }

        let reads = { (title: String) in ToolHints(readOnly: true, destructive: false, declaresDestructive: false, title: title) }
        previewProbe = .success(ServerProbe.Report(serverName: "obsidian-local-rest-api", tools: [
            .init(name: "search", description: "Full-text search across the vault.", hints: reads("Search notes")),
            .init(name: "get_note", description: nil, hints: reads("Read a note")),
            .init(
                name: "append_to_note", description: "Adds text to the end of a note.",
                hints: ToolHints(readOnly: false, destructive: false, declaresDestructive: false, title: "Append to a note")
            ),
            .init(
                name: "delete_note", description: "Moves a note to the trash.",
                hints: ToolHints(readOnly: false, destructive: true, declaresDestructive: true, title: "Delete a note")
            ),
        ]))
        previewImportCandidates = [
            ImportCandidate(source: .claudeDesktop, scope: nil, originalName: "filesystem", config: servers[1], unsupportedReason: nil),
            ImportCandidate(source: .claudeDesktop, scope: nil, originalName: "memory", config: ServerConfig(name: "memory", command: "npx", args: ["-y", "@modelcontextprotocol/server-memory"]), unsupportedReason: nil),
            ImportCandidate(source: .claudeExtensions, scope: nil, originalName: "Apple Reminders", config: ServerConfig(name: "apple-reminders", command: "node", args: ["/Users/you/Library/Application Support/Porchlight/Extensions/apple-reminders/server/index.js"]), unsupportedReason: nil, bundle: ExtensionBundle(source: URL(filePath: "/"), destination: URL(filePath: "/"))),
            ImportCandidate(source: .claudeCode, scope: nil, originalName: "linear", config: nil, unsupportedReason: "Remote server: cloud agents can reach it directly"),
            ImportCandidate(source: .claudeCode, scope: "/Users/you/code/porchlight", originalName: "sqlite", config: ServerConfig(name: "sqlite", command: "uvx", args: ["mcp-server-sqlite", "--db-path", "dev.db"]), unsupportedReason: nil),
            ImportCandidate(source: .cursor, scope: nil, originalName: "obsidian", config: obsidian, unsupportedReason: nil),
        ]

        switch scenario {
        case .waitingForToolApproval:
            pendingApprovals = [ToolApprovalRequest(
                client: ClientIdentity(id: "https://claude.ai/oauth/mcp-oauth-client-metadata", name: "Claude"),
                server: "apple-reminders", tool: "create_reminder", title: "Create reminder",
                arguments: .object(["list": .string("Groceries"), "title": .string("Oat milk"), "dueDate": .string("2026-10-12T09:00:00")])
            )]
        case .switchedOff:
            state = .off
            serverStatus = [:]
        case .waitingForPairing:
            pendingPairings = [PairingRequest(
                id: "p1", code: "482913", clientID: "https://chatgpt.com/oauth/client", clientName: "ChatGPT",
                clientDomain: "chatgpt.com", redirectHost: "chatgpt.com", loopback: false
            )]
        default:
            break
        }
    }
    #endif
}
