import Foundation

/// Routes tunneled requests: `/mcp` to the aggregate of all servers, `/mcp/<name>`
/// to one server. Owns the running servers and applies configuration changes live.
public actor Router: HTTPHandler {
    public typealias StatusSink = @Sendable (_ server: String, _ status: UpstreamStatus) -> Void
    public typealias Approver = @Sendable (ToolApprovalRequest) async -> ToolApproval

    private let environment: [String: String]
    private let log: @Sendable (_ server: String, _ line: String) -> Void
    private let onStatus: StatusSink
    let approve: Approver
    private let onActivity: @Sendable (ActivityEvent) -> Void
    let aggregator = Aggregator()
    var running: [String: (config: ServerConfig, upstream: any Upstream)] = [:]
    /// Enabled servers, in the order they're listed.
    private(set) var order: [String] = []
    /// Client ID → the servers that app may use. Apps not listed may use all of them.
    private var clientAccess: [String: Set<String>] = [:]
    /// server → tool → its hints, from the servers' tool lists.
    var hints: [String: [String: ToolHints]] = [:]

    /// `environment` is the base for every server (e.g. the login shell's); each server's
    /// own `env` is layered on top. `approve` is asked about tool calls whose permission is
    /// "ask"; without one, they're denied.
    public init(
        environment: [String: String],
        log: @escaping @Sendable (_ server: String, _ line: String) -> Void = { server, line in stderrLog("[\(server)] \(line)") },
        onStatus: @escaping StatusSink = { _, _ in },
        approve: @escaping Approver = { _ in .deny },
        onActivity: @escaping @Sendable (ActivityEvent) -> Void = { _ in }
    ) {
        self.environment = environment
        self.log = log
        self.onStatus = onStatus
        self.approve = approve
        self.onActivity = onActivity
    }

    /// Makes the enabled servers in `configs` the running set. Unchanged servers keep
    /// running; changed ones restart (lazily, on next use); removed ones stop.
    public func apply(_ configs: [ServerConfig]) async {
        let wanted = configs.filter(\.enabled)
        let byName = Dictionary(wanted.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for (name, entry) in running {
            if let config = byName[name], config.sameServer(as: entry.config) {
                // Only the policy (or nothing) changed: no restart.
                running[name]?.config = config
            } else {
                await entry.upstream.stop()
                onStatus(name, .idle)
                running[name] = nil
                hints[name] = nil
            }
        }
        for config in wanted where running[config.name] == nil {
            let name = config.name
            let log = self.log
            let onStatus = self.onStatus
            let upstream = config.makeUpstream(environment: environment, log: { log(name, $0) }, onStatus: { onStatus(name, $0) })
            running[name] = (config, upstream)
        }
        order = wanted.map(\.name)
        await aggregator.setUpstreams(order.compactMap { running[$0]?.upstream })
    }

    /// Starts every server now instead of on first use, so a broken command shows up
    /// right away rather than when an app first calls it.
    public func warmUp() {
        for entry in running.values {
            Task { _ = await entry.upstream.initialize() }
        }
    }

    public func stopAll() async {
        await apply([])
    }

    /// Which servers each app may use: client ID → server names. Apps not in the map may
    /// use all servers, including ones added later.
    public func setClientAccess(_ access: [String: Set<String>]) {
        clientAccess = access
    }

    /// The servers an app may use, or nil for all of them. Empty `clientID`: an app with
    /// access to everything.
    func allowedServers(for clientID: String) -> Set<String>? {
        clientID.isEmpty ? nil : clientAccess[clientID]
    }

    public func handle(_ request: HTTPRequest, _ responder: HTTPResponder) async {
        let client = ClientIdentity(headers: request)
        let allowed = allowedServers(for: client.id)
        let queuedAt = request.header(RelayProtocol.queuedAtHeader).flatMap { try? Date($0, strategy: .iso8601) }
        let route = request.route
        if route == "/mcp" {
            let inner = ScopedAggregator(aggregator: aggregator, allowed: allowed)
            let endpoint = GatedEndpoint(inner: inner, scope: .all, client: client, allowed: allowed, queuedAt: queuedAt, router: self)
            return await StreamableHTTP.serve(request, responder, endpoint: endpoint)
        }
        let parts = route.split(separator: "/")
        if parts.count == 2, parts[0] == "mcp", let entry = running[String(parts[1])] {
            if let allowed, !allowed.contains(entry.config.name) {
                let message = "\(client.name) doesn't have access to \(entry.config.name). Change that in Porchlight → Settings → Apps.\n"
                return await responder.respond(403, [("content-type", "text/plain")], body: Data(message.utf8))
            }
            let inner = PassthroughEndpoint(upstream: entry.upstream)
            let endpoint = GatedEndpoint(
                inner: inner, scope: .server(entry.config.name), client: client, allowed: allowed, queuedAt: queuedAt, router: self
            )
            return await StreamableHTTP.serve(request, responder, endpoint: endpoint)
        }
        await responder.respond(404, [("content-type", "text/plain")], body: Data("No such server\n".utf8))
    }

    func record(_ event: ActivityEvent) {
        onActivity(event)
    }
}
