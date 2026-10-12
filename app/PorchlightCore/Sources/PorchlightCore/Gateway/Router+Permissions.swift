import Foundation

// Tool permissions: what each call may do, and which tools an app sees at all.
extension Router {
    enum Decision: Equatable {
        case allowed
        case denied(String)
    }

    func authorize(server: String, tool: String, arguments: JSONValue, client: ClientIdentity, queuedAt: Date?) async -> Decision {
        guard let config = running[server]?.config else { return .denied("\(server) isn't running in Porchlight.") }
        let info = await toolHints(server: server, tool: tool)
        // A tool the server doesn't list gets the most careful defaults.
        let readOnly = info?.readOnly ?? false
        // The relay saved this call by the catalog it had then; queue settings may have changed since.
        if queuedAt != nil, !config.toolPolicy.queuesOffline(tool, readOnly: readOnly, destructive: info?.destructive ?? true) {
            return .denied("\(tool) on \(server) doesn't run from requests saved while the Mac was offline.")
        }
        switch config.toolPolicy.permission(for: tool, readOnly: readOnly) {
        case .allow:
            return .allowed
        case .deny:
            return .denied("The user has blocked \(tool) on \(server) in Porchlight.")
        case .ask:
            let request = ToolApprovalRequest(
                client: client, server: server, tool: tool, title: info?.title, arguments: arguments, queuedAt: queuedAt
            )
            switch await approve(request) {
            case .allowOnce:
                return .allowed
            case .allowAlways:
                running[server]?.config.toolPolicy.overrides[tool] = .allow
                return .allowed
            case .deny:
                return .denied("The user denied this call to \(tool) on their Mac.")
            }
        }
    }

    /// Drops blocked tools from a `tools/list` response, noting each tool's hints on the way.
    func withoutBlockedTools(_ response: JSONValue, scope: GatedEndpoint.Scope) async -> JSONValue {
        guard case .array(let tools)? = response["result"]?["tools"] else { return response }
        var kept: [JSONValue] = []
        for tool in tools {
            guard let name = tool["name"]?.stringValue else { continue }
            guard let target = await knownTarget(of: name, in: scope) else {
                kept.append(tool)
                continue
            }
            let toolHints = ToolHints(tool)
            hints[target.server, default: [:]][target.tool] = toolHints
            if running[target.server]?.config.toolPolicy.permission(for: target.tool, readOnly: toolHints.readOnly) != .deny {
                kept.append(tool)
            }
        }
        var filtered = response
        filtered["result"]?["tools"] = .array(kept)
        return filtered
    }

    /// The tool behind a name in a list that was just fetched for `scope`.
    func knownTarget(of name: String, in scope: GatedEndpoint.Scope) async -> ToolTarget? {
        switch scope {
        case .server(let server): ToolTarget(server: server, tool: name)
        case .all: await aggregator.knownTool(name)
        }
    }

    /// A tool's hints, listing the server's tools if they aren't known yet.
    private func toolHints(server: String, tool: String) async -> ToolHints? {
        if let known = hints[server]?[tool] { return known }
        guard let upstream = running[server]?.upstream else { return nil }
        _ = await withoutBlockedTools(await upstream.request(.rpcRequest("tools/list")), scope: .server(server))
        return hints[server]?[tool]
    }
}
