import Foundation

// What an app sees, for Settings and for the relay to answer with while the Mac is offline.
extension Router {
    /// How many tools an app sees at `/mcp` (all servers it may use, minus blocked tools).
    /// Empty `clientID`: an app with access to everything.
    public func toolCount(for clientID: String) async -> Int {
        let combined = ScopedAggregator(aggregator: aggregator, allowed: allowedServers(for: clientID))
        let listed = await withoutBlockedTools(await combined.call(.rpcRequest("tools/list", id: .int(1)), onProgress: nil), scope: .all)
        guard case .array(let tools)? = listed["result"]?["tools"] else { return 0 }
        return tools.count
    }

    /// What an app sees while the Mac is offline, for the relay to answer with: for `/mcp` and
    /// each server it may use, the `initialize` result, its tools (minus blocked ones), and
    /// which of them queue (see `ToolPolicy.queuesOffline`). Servers that don't answer are left out.
    public func offlineCatalog(for clientID: String) async -> JSONValue {
        let allowed = allowedServers(for: clientID)
        let initialize = JSONValue.rpcRequest("initialize", id: .int(0), params: ["protocolVersion": .string(MCP.supportedVersions[0])])
        let list = JSONValue.rpcRequest("tools/list", id: .int(1))

        var paths: [String: JSONValue] = [:]
        let combined = ScopedAggregator(aggregator: aggregator, allowed: allowed)
        if let result = await combined.call(initialize, onProgress: nil)["result"] {
            let tools = await withoutBlockedTools(await combined.call(list, onProgress: nil), scope: .all)
            paths["/mcp"] = await catalogPath(result, tools, scope: .all)
        }
        for name in order where allowed?.contains(name) ?? true {
            guard let upstream = running[name]?.upstream else { continue }
            let endpoint = PassthroughEndpoint(upstream: upstream)
            guard let result = await endpoint.call(initialize, onProgress: nil)["result"] else { continue }
            let tools = await withoutBlockedTools(await endpoint.call(list, onProgress: nil), scope: .server(name))
            paths["/mcp/\(name)"] = await catalogPath(result, tools, scope: .server(name))
        }
        return .object([
            "protocol_versions": .array(MCP.supportedVersions.map { .string($0) }),
            "paths": .object(paths),
        ])
    }

    private func catalogPath(_ initialize: JSONValue, _ listed: JSONValue, scope: GatedEndpoint.Scope) async -> JSONValue {
        guard case .array(let tools)? = listed["result"]?["tools"] else {
            return .object(["initialize": initialize, "tools": .array([]), "queueable": .array([])])
        }
        var queueable: [JSONValue] = []
        for tool in tools {
            guard let name = tool["name"]?.stringValue, let target = await knownTarget(of: name, in: scope),
                  let policy = running[target.server]?.config.toolPolicy,
                  let toolHints = hints[target.server]?[target.tool]
            else { continue }
            if policy.queuesOffline(target.tool, readOnly: toolHints.readOnly, destructive: toolHints.destructive) {
                queueable.append(.string(name))
            }
        }
        return .object(["initialize": initialize, "tools": .array(tools), "queueable": .array(queueable)])
    }
}
