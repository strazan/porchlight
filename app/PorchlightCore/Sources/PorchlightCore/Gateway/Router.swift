import Foundation

/// Routes tunneled requests: `/mcp` to the aggregate of all servers, `/mcp/<name>`
/// to one server. Owns the running servers and applies configuration changes live.
public actor Router: HTTPHandler {
    public typealias StatusSink = @Sendable (_ server: String, _ status: UpstreamStatus) -> Void

    private let environment: [String: String]
    private let log: @Sendable (_ server: String, _ line: String) -> Void
    private let onStatus: StatusSink
    private let aggregator = Aggregator()
    private var running: [String: (config: ServerConfig, upstream: any Upstream)] = [:]
    private var order: [String] = []

    /// `environment` is the base for every server (e.g. the login shell's); each server's
    /// own `env` is layered on top.
    public init(
        environment: [String: String],
        log: @escaping @Sendable (_ server: String, _ line: String) -> Void = { server, line in stderrLog("[\(server)] \(line)") },
        onStatus: @escaping StatusSink = { _, _ in }
    ) {
        self.environment = environment
        self.log = log
        self.onStatus = onStatus
    }

    /// Makes the enabled servers in `configs` the running set. Unchanged servers keep
    /// running; changed ones restart (lazily, on next use); removed ones stop.
    public func apply(_ configs: [ServerConfig]) async {
        let wanted = configs.filter(\.enabled)
        let wantedNames = Set(wanted.map(\.name))
        for (name, entry) in running where !wantedNames.contains(name) || !wanted.contains(entry.config) {
            await entry.upstream.stop()
            onStatus(name, .idle)
            running[name] = nil
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
        public let toolCount: Int
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
        let tools = await upstream.request(.object(["jsonrpc": .string("2.0"), "method": .string("tools/list")]))
        let count: Int = if case .array(let items)? = tools["result"]?["tools"] { items.count } else { 0 }
        return .success(ProbeResult(serverName: result["serverInfo"]?["name"]?.stringValue ?? config.name, toolCount: count))
    }

    public struct ProbeError: Error, Sendable, Equatable {
        public let message: String
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

    public func handle(_ request: HTTPRequest, _ responder: HTTPResponder) async {
        let route = request.route
        if route == "/mcp" {
            return await StreamableHTTP.serve(request, responder, endpoint: aggregator)
        }
        let parts = route.split(separator: "/")
        if parts.count == 2, parts[0] == "mcp", let entry = running[String(parts[1])] {
            return await StreamableHTTP.serve(request, responder, endpoint: PassthroughEndpoint(upstream: entry.upstream))
        }
        await responder.respond(404, [("content-type", "text/plain")], body: Data("No such server\n".utf8))
    }
}
