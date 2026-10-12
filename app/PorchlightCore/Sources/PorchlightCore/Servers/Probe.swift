import Foundation

/// What a server says about one of its tools. `destructive` follows MCP's default: a tool
/// that isn't read-only is destructive unless it says otherwise.
public struct ToolHints: Sendable, Equatable {
    public let readOnly: Bool
    public let destructive: Bool
    /// Says outright that it's destructive (rather than being so by default), for a badge.
    public let declaresDestructive: Bool
    public let title: String?

    init(_ tool: JSONValue) {
        let annotations = tool["annotations"]
        readOnly = annotations?["readOnlyHint"] == .bool(true)
        destructive = !readOnly && annotations?["destructiveHint"] != .bool(false)
        declaresDestructive = annotations?["destructiveHint"] == .bool(true)
        title = tool["title"]?.stringValue ?? annotations?["title"]?.stringValue
    }

    public init(readOnly: Bool, destructive: Bool, declaresDestructive: Bool, title: String?) {
        self.readOnly = readOnly
        self.destructive = destructive
        self.declaresDestructive = declaresDestructive
        self.title = title
    }

    /// Neither read-only nor destructive: it adds something. These queue offline by default.
    public var additive: Bool { !readOnly && !destructive }
}

public struct ToolSummary: Sendable, Equatable, Identifiable {
    public let name: String
    public let description: String?
    public let hints: ToolHints

    public var id: String { name }

    public init(name: String, description: String?, hints: ToolHints) {
        self.name = name
        self.description = description
        self.hints = hints
    }
}

/// Connects to a server the way an app would (initialize, list tools) and reports what it
/// found, or the error. For checking a config before saving it.
public enum ServerProbe {
    public struct Report: Sendable, Equatable {
        /// The name the server reports for itself.
        public let serverName: String
        public let tools: [ToolSummary]

        public init(serverName: String, tools: [ToolSummary]) {
            self.serverName = serverName
            self.tools = tools
        }
    }

    public struct Failure: Error, Sendable, Equatable {
        public let message: String

        public init(message: String) {
            self.message = message
        }
    }

    public static func run(_ config: ServerConfig, environment: [String: String]) async -> Result<Report, Failure> {
        let upstream = config.makeUpstream(environment: environment, log: { _ in }, onStatus: { _ in })
        defer { Task { await upstream.stop() } }
        let initialized = await upstream.initialize()
        guard let result = initialized["result"] else {
            return .failure(Failure(message: initialized.failure ?? "No answer"))
        }
        let listed = await upstream.request(.rpcRequest("tools/list"))
        var tools: [ToolSummary] = []
        if case .array(let items)? = listed["result"]?["tools"] {
            tools = items.compactMap { item in
                guard let name = item["name"]?.stringValue else { return nil }
                return ToolSummary(name: name, description: item["description"]?.stringValue, hints: ToolHints(item))
            }
        }
        return .success(Report(serverName: result["serverInfo"]?["name"]?.stringValue ?? config.name, tools: tools))
    }
}
