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
    var queuedAt: Date? = nil
    let router: Router

    func call(_ request: JSONValue, onProgress: ProgressSink?) async -> JSONValue {
        let started = ContinuousClock.now
        let method = request.rpcMethod ?? "?"
        var server: String? = if case .server(let name) = scope { name } else { nil }
        var tool: String?

        if method == "tools/call", let name = request["params"]?["name"]?.stringValue {
            tool = name
            if let target = await target(of: name) {
                server = target.server
                tool = target.tool
                let decision = await router.authorize(
                    server: target.server, tool: target.tool,
                    arguments: request["params"]?["arguments"] ?? .object([:]), client: client, queuedAt: queuedAt
                )
                if case .denied(let reason) = decision {
                    await record(method, server, tool, started, .denied(reason))
                    return Self.declined(request.rpcID, reason)
                }
            }
        }

        var response = await inner.call(request, onProgress: onProgress)
        if method == "tools/list" { response = await router.withoutDeniedTools(response, scope: scope) }

        let outcome: ActivityEvent.Outcome =
            if let message = response["error"]?["message"]?.stringValue { .error(message) }
            else if response["result"]?["isError"] == .bool(true) { .error(Self.text(of: response) ?? "Tool reported an error") }
            else { .ok }
        await record(method, server, tool, started, outcome)
        return response
    }

    func notify(_ notification: JSONValue) async {
        await inner.notify(notification)
    }

    private func target(of name: String) async -> (server: String, tool: String)? {
        switch scope {
        case .server(let server): (server, name)
        case .all: await router.resolveTool(name, allowed: allowed)
        }
    }

    private func record(_ method: String, _ server: String?, _ tool: String?, _ started: ContinuousClock.Instant, _ outcome: ActivityEvent.Outcome) async {
        await router.record(ActivityEvent(
            date: Date(), client: client, server: server, method: method, tool: tool,
            duration: ContinuousClock.now - started, outcome: outcome, queuedAt: queuedAt
        ))
    }

    /// A tool result (not a protocol error), so the model sees why the call didn't happen.
    static func declined(_ id: JSONValue?, _ reason: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id ?? .null,
            "result": .object([
                "content": .array([.object(["type": .string("text"), "text": .string(reason)])]),
                "isError": .bool(true),
            ]),
        ])
    }

    static func text(of response: JSONValue) -> String? {
        guard case .array(let content)? = response["result"]?["content"] else { return nil }
        return content.first?["text"]?.stringValue
    }
}
