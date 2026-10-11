import Foundation

/// Routes tunneled requests: `/mcp` to the aggregate of all servers, `/mcp/<name>`
/// to one server. Owns the running servers and applies configuration changes live.
public actor Router: HTTPHandler {
    public typealias StatusSink = @Sendable (_ server: String, _ status: UpstreamStatus) -> Void
    public typealias Approver = @Sendable (ToolApprovalRequest) async -> ToolApproval

    private let environment: [String: String]
    private let log: @Sendable (_ server: String, _ line: String) -> Void
    private let onStatus: StatusSink
    private let approve: Approver
    private let onActivity: @Sendable (ActivityEvent) -> Void
    private let aggregator = Aggregator()
    private var running: [String: (config: ServerConfig, upstream: any Upstream)] = [:]
    private var order: [String] = []
    /// Client ID → the servers that app may use. Apps not listed may use all of them.
    private var clientAccess: [String: Set<String>] = [:]
    /// server → tool → its hints and title, from the servers' tool lists.
    private var annotations: [String: [String: ToolHints]] = [:]

    /// What a server says about one of its tools. `destructive` follows MCP's default: a tool
    /// that isn't read-only is destructive unless it says otherwise.
    struct ToolHints {
        var readOnly: Bool
        var destructive: Bool
        var title: String?

        init(_ tool: JSONValue) {
            readOnly = tool["annotations"]?["readOnlyHint"] == .bool(true)
            destructive = !readOnly && tool["annotations"]?["destructiveHint"] != .bool(false)
            title = tool["title"]?.stringValue
        }
    }

    /// `environment` is the base for every server (e.g. the login shell's); each server's
    /// own `env` is layered on top. `approve` is asked about tool calls whose permission is
    /// "ask"; without one, they're declined.
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
                annotations[name] = nil
            }
        }
        for config in wanted where running[config.name] == nil {
            running[config.name] = (config, makeUpstream(config))
        }
        order = wanted.map(\.name)
        await aggregator.setUpstreams(order.compactMap { running[$0]?.upstream })
    }

    public struct ProbeResult: Sendable, Equatable {
        /// The name the server reports for itself.
        public let serverName: String
        public let tools: [ToolSummary]

        public var toolCount: Int { tools.count }

        public init(serverName: String, tools: [ToolSummary]) {
            self.serverName = serverName
            self.tools = tools
        }
    }

    public struct ToolSummary: Sendable, Equatable, Identifiable {
        public let name: String
        public let title: String?
        public let description: String?
        public let readOnly: Bool
        /// Says it's destructive (for a badge; see `additive` for queueing).
        public let destructive: Bool
        /// Says it neither only reads nor destroys anything: it adds. Queues offline by default.
        public let additive: Bool

        public var id: String { name }

        public init(name: String, title: String?, description: String?, readOnly: Bool, destructive: Bool, additive: Bool = false) {
            self.name = name
            self.title = title
            self.description = description
            self.readOnly = readOnly
            self.destructive = destructive
            self.additive = additive
        }
    }

    /// Connects to a server the way a client would (initialize, list tools) and reports
    /// what it found, or the error. For checking a config before saving it.
    public static func probe(_ config: ServerConfig, environment: [String: String]) async -> Result<ProbeResult, ProbeError> {
        let upstream = makeUpstream(config, environment: environment, log: { _ in }, onStatus: { _ in })
        defer { Task { await upstream.stop() } }
        let initialized = await upstream.initialize()
        guard let result = initialized["result"] else {
            return .failure(ProbeError(message: initialized["error"]?["message"]?.stringValue ?? "No answer"))
        }
        let listed = await upstream.request(.object(["jsonrpc": .string("2.0"), "method": .string("tools/list")]))
        var tools: [ToolSummary] = []
        if case .array(let items)? = listed["result"]?["tools"] {
            tools = items.compactMap { item in
                guard let name = item["name"]?.stringValue else { return nil }
                return ToolSummary(
                    name: name,
                    title: item["title"]?.stringValue ?? item["annotations"]?["title"]?.stringValue,
                    description: item["description"]?.stringValue,
                    readOnly: item["annotations"]?["readOnlyHint"] == .bool(true),
                    destructive: item["annotations"]?["destructiveHint"] == .bool(true),
                    additive: !ToolHints(item).destructive && !ToolHints(item).readOnly
                )
            }
        }
        return .success(ProbeResult(serverName: result["serverInfo"]?["name"]?.stringValue ?? config.name, tools: tools))
    }

    public struct ProbeError: Error, Sendable, Equatable {
        public let message: String

        public init(message: String) {
            self.message = message
        }
    }

    private func makeUpstream(_ config: ServerConfig) -> any Upstream {
        let name = config.name
        let log = self.log
        let onStatus = self.onStatus
        return Self.makeUpstream(config, environment: environment, log: { log(name, $0) }, onStatus: { onStatus(name, $0) })
    }

    private static func makeUpstream(
        _ config: ServerConfig,
        environment: [String: String],
        log: @escaping LogSink,
        onStatus: @escaping @Sendable (UpstreamStatus) -> Void
    ) -> any Upstream {
        let name = config.name
        switch config.transport {
        case .stdio:
            return StdioUpstream(
                name: name,
                command: config.commandLine,
                environment: environment.merging(config.env) { _, own in own },
                log: log,
                onStatus: onStatus
            )
        case .http:
            // A config that isn't runnable fails on first use, with its status saying why.
            return HTTPUpstream(
                name: name,
                url: URL(string: config.url) ?? URL(string: "http://invalid.invalid")!,
                headers: config.headers,
                log: log,
                onStatus: onStatus
            )
        }
    }

    /// Starts every server now instead of on first use, so a broken command shows up
    /// right away rather than when a client first calls it.
    public func warmUp() {
        for entry in running.values {
            Task { _ = await entry.upstream.initialize() }
        }
    }

    public func stopAll() async {
        await apply([])
    }

    /// Set by RelayClient on requests saved while the Mac was offline (the relay drops any
    /// `porchlight-*` header an app sends, so apps can't set it).
    static let queuedAtHeader = "porchlight-queued-at"

    public func handle(_ request: HTTPRequest, _ responder: HTTPResponder) async {
        let client = ClientIdentity(headers: request)
        let allowed = client.id.isEmpty ? nil : clientAccess[client.id]
        let queuedAt = request.header(Self.queuedAtHeader).flatMap { try? Date($0, strategy: .iso8601) }
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

    // MARK: Permissions

    /// Changes one tool's permission on a running server, until the next `apply`. (The app
    /// saves overrides in the server's config instead; the CLI has nowhere to save them.)
    public func setPermission(_ permission: ToolPermission, tool: String, server: String) {
        running[server]?.config.toolPolicy.overrides[tool] = permission
    }

    enum Decision: Equatable {
        case allowed
        case denied(String)
    }

    func authorize(server: String, tool: String, arguments: JSONValue, client: ClientIdentity, queuedAt: Date? = nil) async -> Decision {
        guard let config = running[server]?.config else { return .allowed } // the call fails on its own
        let info = await toolInfo(server: server, tool: tool)
        switch config.toolPolicy.permission(for: tool, readOnly: info?.readOnly ?? false) {
        case .allow:
            return .allowed
        case .deny:
            return .denied("The user has blocked \(tool) on \(server) in Porchlight.")
        case .ask:
            let request = ToolApprovalRequest(
                clientID: client.id, clientName: client.name, server: server, tool: tool, title: info?.title,
                arguments: arguments, queuedAt: queuedAt
            )
            switch await approve(request) {
            case .allowOnce, .allowAlways: return .allowed
            case .deny: return .denied("The user declined this call to \(tool) on their Mac.")
            }
        }
    }

    /// Drops denied tools from a `tools/list` response, noting annotations on the way.
    func withoutDeniedTools(_ response: JSONValue, scope: GatedEndpoint.Scope) async -> JSONValue {
        guard case .array(let tools)? = response["result"]?["tools"] else { return response }
        var kept: [JSONValue] = []
        for tool in tools {
            guard let name = tool["name"]?.stringValue else { continue }
            let target: (server: String, tool: String)? = switch scope {
            case .server(let server): (server, name)
            case .all: await aggregator.knownTool(name)
            }
            guard let target else {
                kept.append(tool)
                continue
            }
            let hints = ToolHints(tool)
            annotations[target.server, default: [:]][target.tool] = hints
            if running[target.server]?.config.toolPolicy.permission(for: target.tool, readOnly: hints.readOnly) != .deny {
                kept.append(tool)
            }
        }
        var filtered = response
        filtered["result"]?["tools"] = .array(kept)
        return filtered
    }

    func resolveTool(_ alias: String, allowed: Set<String>?) async -> (server: String, tool: String)? {
        await aggregator.resolveTool(alias, allowed: allowed)
    }

    /// Which servers each app may use: client ID → server names. Apps not in the map may
    /// use all servers, including ones added later.
    public func setClientAccess(_ access: [String: Set<String>]) {
        clientAccess = access
    }

    /// A tool's hints and title, listing the server's tools if they aren't known yet.
    private func toolInfo(server: String, tool: String) async -> ToolHints? {
        if let known = annotations[server]?[tool] { return known }
        guard let upstream = running[server]?.upstream else { return nil }
        let listed = await upstream.request(.object(["jsonrpc": .string("2.0"), "method": .string("tools/list")]))
        _ = await withoutDeniedTools(listed, scope: .server(server))
        return annotations[server]?[tool]
    }

    func record(_ event: ActivityEvent) {
        onActivity(event)
    }

    /// How many tools an app sees at `/mcp` (all servers it may use, minus blocked tools).
    /// Empty `clientID`: an app with access to everything.
    public func toolCount(for clientID: String) async -> Int {
        let allowed = clientID.isEmpty ? nil : clientAccess[clientID]
        let list: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/list")])
        let listed = await ScopedAggregator(aggregator: aggregator, allowed: allowed).call(list, onProgress: nil)
        guard case .array(let tools)? = await withoutDeniedTools(listed, scope: .all)["result"]?["tools"] else { return 0 }
        return tools.count
    }

    // MARK: Offline catalog

    /// What an app sees while the Mac is offline, for the relay to answer with: for `/mcp` and
    /// each server it may use, the `initialize` result, its tools (minus blocked ones), and
    /// which of them queue (see `ToolPolicy.queuesOffline`). Servers that don't answer are left out.
    public func offlineCatalog(for clientID: String) async -> JSONValue {
        let allowed = clientID.isEmpty ? nil : clientAccess[clientID]
        let initialize: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .int(0), "method": .string("initialize"),
            "params": .object(["protocolVersion": .string(Aggregator.supportedVersions[0])]),
        ])
        let list: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/list")])

        var paths: [String: JSONValue] = [:]
        let combined = ScopedAggregator(aggregator: aggregator, allowed: allowed)
        if let result = await combined.call(initialize, onProgress: nil)["result"] {
            let tools = await withoutDeniedTools(await combined.call(list, onProgress: nil), scope: .all)
            paths["/mcp"] = await catalogPath(result, tools, scope: .all)
        }
        for name in order where allowed?.contains(name) ?? true {
            guard let upstream = running[name]?.upstream else { continue }
            let endpoint = PassthroughEndpoint(upstream: upstream)
            guard let result = await endpoint.call(initialize, onProgress: nil)["result"] else { continue }
            let tools = await withoutDeniedTools(await endpoint.call(list, onProgress: nil), scope: .server(name))
            paths["/mcp/\(name)"] = await catalogPath(result, tools, scope: .server(name))
        }
        return .object([
            "protocol_versions": .array(Aggregator.supportedVersions.map { .string($0) }),
            "paths": .object(paths),
        ])
    }

    private func catalogPath(_ initialize: JSONValue, _ listed: JSONValue, scope: GatedEndpoint.Scope) async -> JSONValue {
        guard case .array(let tools)? = listed["result"]?["tools"] else {
            return .object(["initialize": initialize, "tools": .array([]), "queueable": .array([])])
        }
        var queueable: [JSONValue] = []
        for tool in tools {
            guard let name = tool["name"]?.stringValue else { continue }
            let target: (server: String, tool: String)? = switch scope {
            case .server(let server): (server, name)
            case .all: await aggregator.knownTool(name)
            }
            guard let target, let policy = running[target.server]?.config.toolPolicy,
                  let hints = annotations[target.server]?[target.tool]
            else { continue }
            if policy.queuesOffline(target.tool, readOnly: hints.readOnly, destructive: hints.destructive) {
                queueable.append(.string(name))
            }
        }
        return .object(["initialize": initialize, "tools": .array(tools), "queueable": .array(queueable)])
    }
}
