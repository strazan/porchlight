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

extension Router {
    /// Inspect the running connection so choosing tools doesn't start a second server.
    public func toolsForLending(on server: String) async -> Result<[ToolSummary], ServerProbe.Failure> {
        guard let upstream = running[server]?.upstream else {
            return .failure(.init(message: "This server isn't running. Turn Porchlight on to choose tools."))
        }
        var tools: [ToolSummary] = []
        var cursor: JSONValue?
        var seen: Set<String> = []
        repeat {
            let response = await upstream.request(.rpcRequest("tools/list", params: cursor.map { ["cursor": $0] } ?? [:]))
            guard case .array(let items)? = response["result"]?["tools"] else {
                return .failure(.init(message: response.failure ?? "The server didn't return a tool list."))
            }
            for item in items {
                guard let name = item["name"]?.stringValue, !tools.contains(where: { $0.name == name }) else { continue }
                let info = ToolHints(item)
                hints[server, default: [:]][name] = info
                tools.append(ToolSummary(name: name, description: item["description"]?.stringValue, hints: info))
            }
            cursor = response["result"]?["nextCursor"]
            if cursor == .null { cursor = nil }
            if let cursor, !seen.insert(String(decoding: cursor.serialized(), as: UTF8.self)).inserted {
                return .failure(.init(message: "The server repeated its tool-list cursor."))
            }
        } while cursor != nil
        return .success(tools)
    }
}
