import Foundation

/// Wraps an endpoint for one request: enforces tool permissions and records activity.
struct GatedEndpoint: MCPEndpoint {
    enum Scope: Sendable {
        /// The combined `/mcp` endpoint, where tool names are `<server>__<tool>`.
        case all
        case server(String)
    }

    let inner: any MCPEndpoint
    let scope: Scope
    let client: ClientIdentity
    /// The servers this app may use, or nil for all.
    let allowed: Set<String>?
    /// When the app made the request, if it was saved while the Mac was offline.
    let queuedAt: Date?
    let router: Router

    func call(_ request: JSONValue, onProgress: ProgressSink?) async -> JSONValue {
        let started = ContinuousClock.now
        let method = request.rpcMethod ?? "?"
        var server: String? = if case .server(let name) = scope { name } else { nil }
        var tool: String?

        if method == "tools/call" {
            // Every call is checked before it runs: one this can't place never reaches a server.
            guard let name = request["params"]?["name"]?.stringValue else {
                return .rpcError(id: request.rpcID, code: .invalidParams, message: "Missing tool name")
            }
            tool = name
            guard let target = await target(of: name) else {
                let reason = "Unknown tool: \(name)"
                await record(method, server, tool, started, .error(reason))
                return .rpcError(id: request.rpcID, code: .invalidParams, message: reason)
            }
            server = target.server
            tool = target.tool
            let decision = await router.authorize(
                server: target.server, tool: target.tool,
                arguments: request["params"]?["arguments"] ?? .object([:]), client: client, queuedAt: queuedAt
            )
            if case .denied(let reason) = decision {
                await record(method, server, tool, started, .denied(reason))
                // A tool result rather than a protocol error, so the model sees why it didn't run.
                return .toolResult(id: request.rpcID, reason, isError: true)
            }
        }

        var response = await inner.call(request, onProgress: onProgress)
        if method == "tools/list" { response = await router.withoutBlockedTools(response, scope: scope) }
        await record(method, server, tool, started, response.failure.map(ActivityEvent.Outcome.error) ?? .ok)
        return response
    }

    func notify(_ notification: JSONValue) async {
        await inner.notify(notification)
    }

    private func target(of name: String) async -> ToolTarget? {
        switch scope {
        case .server(let server): ToolTarget(server: server, tool: name)
        case .all: await router.aggregator.resolveTool(name, allowed: allowed)
        }
    }

    private func record(_ method: String, _ server: String?, _ tool: String?, _ started: ContinuousClock.Instant, _ outcome: ActivityEvent.Outcome) async {
        await router.record(ActivityEvent(
            date: Date(), client: client, server: server, method: method, tool: tool,
            duration: ContinuousClock.now - started, outcome: outcome, queuedAt: queuedAt
        ))
    }
}
