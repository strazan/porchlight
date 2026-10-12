import CryptoKit
import Foundation

/// Presents every upstream as one MCP server, at `/mcp`.
///
/// Tools and prompts are renamed `<server>__<name>` (kept within the 64-character,
/// `[A-Za-z0-9_-]` limit clients enforce). Resources keep their URIs and are routed by
/// remembering which server listed them.
///
/// Each call can be limited to the servers one app may use (`allowed`); the others don't
/// appear in its lists and can't be reached by name.
actor Aggregator {
    static let separator = "__"
    static let maxNameLength = 64
    /// How long a server's line in the `initialize` instructions may be.
    static let summaryLength = 200

    private var upstreams: [any Upstream] = []
    private var toolRoutes: [String: Route] = [:]
    private var promptRoutes: [String: Route] = [:]
    private var resourceRoutes: [String: String] = [:]

    struct Route: Equatable {
        let server: String
        let name: String
    }

    func setUpstreams(_ upstreams: [any Upstream]) {
        self.upstreams = upstreams
        let names = Set(upstreams.map(\.name))
        toolRoutes = toolRoutes.filter { names.contains($0.value.server) }
        promptRoutes = promptRoutes.filter { names.contains($0.value.server) }
        resourceRoutes = resourceRoutes.filter { names.contains($0.value) }
    }

    /// `allowed`: the servers this caller may use, or nil for all of them.
    func call(_ request: JSONValue, onProgress: ProgressSink?, allowed: Set<String>?) async -> JSONValue {
        let params = request["params"] ?? .object([:])
        var response: JSONValue
        switch request.rpcMethod {
        case "initialize": response = .rpcResult(await initializeResult(params, allowed: allowed))
        case "ping": response = .rpcResult(.object([:]))
        case "tools/list": response = .rpcResult(.object(["tools": .array(await listTools(allowed: allowed))]))
        case "tools/call": response = await callRenamed(request, .tool, allowed: allowed, onProgress: onProgress)
        case "prompts/list": response = .rpcResult(.object(["prompts": .array(await listPrompts(allowed: allowed))]))
        case "prompts/get": response = await callRenamed(request, .prompt, allowed: allowed, onProgress: nil)
        case "resources/list": response = .rpcResult(.object(["resources": .array(await listResources(allowed: allowed))]))
        case "resources/templates/list":
            response = .rpcResult(.object(["resourceTemplates": .array(await listTemplates(allowed: allowed))]))
        case "resources/read": response = await readResource(request, allowed: allowed)
        case "logging/setLevel":
            for upstream in await upstreams(with: "logging", allowed: allowed) { _ = await upstream.request(request) }
            response = .rpcResult(.object([:]))
        default:
            response = .rpcError(id: nil, code: .methodNotFound, message: "Method not found: \(request.rpcMethod ?? "?")")
        }
        response["id"] = request.rpcID ?? .null
        return response
    }

    // MARK: initialize

    private func initializeResult(_ params: JSONValue, allowed: Set<String>?) async -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue ?? ""
        let version = MCP.supportedVersions.contains(requested) ? requested : MCP.preferredVersion
        var servers: [String] = []
        for upstream in visible(allowed) {
            let about = Self.summary(of: await upstream.handshake)
            servers.append(about.map { "- \(upstream.name): \($0)" } ?? "- \(upstream.name)")
        }
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object([
                "tools": .object([:]),
                "prompts": .object([:]),
                "resources": .object([:]),
                "logging": .object([:]),
            ]),
            "serverInfo": .object(["name": .string("porchlight"), "title": .string("Porchlight"), "version": .string(Porchlight.version)]),
            "instructions": .string(
                "Porchlight combines MCP servers running on the user's Mac. Tool and prompt names are "
                    + "prefixed with their server: <server>__<name>. Pick tools from the server that fits the request.\n\n"
                    + "Servers:\n" + servers.joined(separator: "\n")
            ),
        ])
    }

    /// What a server says it's for, in a line: the start of its instructions, else its
    /// description or title. Nil for servers that haven't connected yet, or say nothing.
    static func summary(of handshake: JSONValue?) -> String? {
        let info = handshake?["serverInfo"]
        let candidates = [handshake?["instructions"], info?["description"], info?["title"]].compactMap { $0?.stringValue }
        guard let text = candidates.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        let paragraph = text.components(separatedBy: "\n\n").first ?? text
        let line = paragraph.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > summaryLength ? String(line.prefix(summaryLength - 1)) + "…" : line
    }

    // MARK: Lists

    private func listTools(allowed: Set<String>?) async -> [JSONValue] {
        var routes: [String: Route] = [:]
        let tools = await collect("tools/list", key: "tools", capability: "tools", allowed: allowed).map { server, tool in
            guard let name = tool["name"]?.stringValue else { return tool }
            let alias = Self.alias(server: server, name: name)
            routes[alias] = Route(server: server, name: name)
            var renamed = tool
            renamed["name"] = .string(alias)
            if tool["title"] == nil { renamed["title"] = .string(name) }
            return renamed
        }
        toolRoutes = Self.merge(toolRoutes, routes, replacing: Set(visible(allowed).map(\.name)))
        return tools
    }

    private func listPrompts(allowed: Set<String>?) async -> [JSONValue] {
        var routes: [String: Route] = [:]
        let prompts = await collect("prompts/list", key: "prompts", capability: "prompts", allowed: allowed).map { server, prompt in
            guard let name = prompt["name"]?.stringValue else { return prompt }
            let alias = Self.alias(server: server, name: name)
            routes[alias] = Route(server: server, name: name)
            var renamed = prompt
            renamed["name"] = .string(alias)
            return renamed
        }
        promptRoutes = Self.merge(promptRoutes, routes, replacing: Set(visible(allowed).map(\.name)))
        return prompts
    }

    private func listResources(allowed: Set<String>?) async -> [JSONValue] {
        let listed = await collect("resources/list", key: "resources", capability: "resources", allowed: allowed)
        for (server, resource) in listed {
            if let uri = resource["uri"]?.stringValue { resourceRoutes[uri] = server }
        }
        return listed.map(\.1)
    }

    private func listTemplates(allowed: Set<String>?) async -> [JSONValue] {
        await collect("resources/templates/list", key: "resourceTemplates", capability: "resources", allowed: allowed).map(\.1)
    }

    /// Lists `key` from every upstream that declares `capability`, following pagination.
    /// A server that fails contributes nothing rather than failing the whole list.
    private func collect(_ method: String, key: String, capability: String, allowed: Set<String>?) async -> [(String, JSONValue)] {
        let candidates = await upstreams(with: capability, allowed: allowed)
        return await withTaskGroup(of: (Int, [(String, JSONValue)]).self) { group in
            for (index, upstream) in candidates.enumerated() {
                group.addTask {
                    var items: [(String, JSONValue)] = []
                    var cursor: JSONValue?
                    repeat {
                        var params: [String: JSONValue] = [:]
                        if let cursor { params["cursor"] = cursor }
                        let response = await upstream.request(.rpcRequest(method, params: params))
                        guard case .array(let page)? = response["result"]?[key] else { break }
                        items += page.map { (upstream.name, $0) }
                        cursor = response["result"]?["nextCursor"]
                        if cursor == .null { cursor = nil }
                    } while cursor != nil
                    return (index, items)
                }
            }
            // Keep server order stable so lists don't shuffle between calls.
            var results: [(Int, [(String, JSONValue)])] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    /// The servers a caller may use.
    private func visible(_ allowed: Set<String>?) -> [any Upstream] {
        guard let allowed else { return upstreams }
        return upstreams.filter { allowed.contains($0.name) }
    }

    private func upstreams(with capability: String, allowed: Set<String>?) async -> [any Upstream] {
        var matching: [any Upstream] = []
        for upstream in visible(allowed) where await upstream.capabilities()?[capability] != nil {
            matching.append(upstream)
        }
        return matching
    }

    // MARK: Routed calls

    enum RenamedKind {
        case tool
        case prompt
    }

    /// `tools/call` and `prompts/get`: map the alias back to its server and original name.
    private func callRenamed(_ request: JSONValue, _ kind: RenamedKind, allowed: Set<String>?, onProgress: ProgressSink?) async -> JSONValue {
        guard let alias = request["params"]?["name"]?.stringValue else {
            return .rpcError(id: nil, code: .invalidParams, message: "Missing name")
        }
        // A client may call without listing first in this process (e.g. after a restart).
        if route(alias, kind) == nil {
            switch kind {
            case .tool: _ = await listTools(allowed: allowed)
            case .prompt: _ = await listPrompts(allowed: allowed)
            }
        }
        guard let route = route(alias, kind),
              let upstream = visible(allowed).first(where: { $0.name == route.server })
        else {
            return .rpcError(id: nil, code: .invalidParams, message: "Unknown name: \(alias)")
        }
        var forwarded = request
        forwarded["params"]?["name"] = .string(route.name)
        return await upstream.request(forwarded, onProgress: onProgress)
    }

    /// The server and original name behind a combined tool name, among `allowed` servers.
    func resolveTool(_ alias: String, allowed: Set<String>?) async -> ToolTarget? {
        if toolRoutes[alias] == nil { _ = await listTools(allowed: allowed) }
        guard let route = toolRoutes[alias], allowed?.contains(route.server) ?? true else { return nil }
        return ToolTarget(server: route.server, tool: route.name)
    }

    /// Like `resolveTool`, without listing: for names that were just listed.
    func knownTool(_ alias: String) -> ToolTarget? {
        toolRoutes[alias].map { ToolTarget(server: $0.server, tool: $0.name) }
    }

    private func route(_ alias: String, _ kind: RenamedKind) -> Route? {
        switch kind {
        case .tool: toolRoutes[alias]
        case .prompt: promptRoutes[alias]
        }
    }

    private func readResource(_ request: JSONValue, allowed: Set<String>?) async -> JSONValue {
        guard let uri = request["params"]?["uri"]?.stringValue else {
            return .rpcError(id: nil, code: .invalidParams, message: "Missing uri")
        }
        if resourceRoutes[uri] == nil { _ = await listResources(allowed: allowed) }
        if let server = resourceRoutes[uri] {
            guard let upstream = visible(allowed).first(where: { $0.name == server }) else {
                return .rpcError(id: nil, code: .resourceNotFound, message: "Resource not found: \(uri)")
            }
            return await upstream.request(request)
        }
        // Possibly a templated URI: ask each server that has resources until one answers.
        for upstream in await upstreams(with: "resources", allowed: allowed) {
            let response = await upstream.request(request)
            if response["result"] != nil { return response }
        }
        return .rpcError(id: nil, code: .resourceNotFound, message: "Resource not found: \(uri)")
    }

    // MARK: Helpers

    /// `table` with the entries for `servers` replaced by `fresh`: a listing for some
    /// servers mustn't forget the routes other callers listed.
    static func merge(_ table: [String: Route], _ fresh: [String: Route], replacing servers: Set<String>) -> [String: Route] {
        table.filter { !servers.contains($0.value.server) }.merging(fresh) { _, new in new }
    }

    /// `<server>__<name>`, made to fit `^[A-Za-z0-9_-]{1,64}$`. Over-long names keep a
    /// hash suffix so they stay unique.
    static func alias(server: String, name: String) -> String {
        let full = server + separator + name
        let sanitized = String(full.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
        if sanitized == full, full.count <= maxNameLength { return full }
        // Sanitizing can make two names collide and truncating can too; the hash keeps them apart.
        let digest = SHA256.hash(data: Data(full.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return String(sanitized.prefix(maxNameLength - digest.count - 1)) + "_" + digest
    }
}

/// A tool behind a name an app sees: its server, and the server's name for it.
struct ToolTarget: Equatable, Sendable {
    let server: String
    let tool: String
}

/// The aggregate as one app sees it: only the servers it may use.
struct ScopedAggregator: MCPEndpoint {
    let aggregator: Aggregator
    let allowed: Set<String>?

    func call(_ request: JSONValue, onProgress: ProgressSink?) async -> JSONValue {
        await aggregator.call(request, onProgress: onProgress, allowed: allowed)
    }

    func notify(_ notification: JSONValue) async {
        // Nothing to forward: cancellation arrives through the relay, and the handshake with
        // each server is Porchlight's own.
    }
}
