import Foundation

/// A server found in another app's MCP config.
public struct ImportCandidate: Sendable, Identifiable, Hashable {
    public enum Source: String, Sendable, Hashable, CaseIterable {
        case claudeDesktop = "Claude Desktop"
        case claudeCode = "Claude Code"
        case cursor = "Cursor"
    }

    public var id: String { "\(source.rawValue)/\(scope ?? "")/\(originalName)" }
    public let source: Source
    /// For project-scoped entries (Claude Code), the project path.
    public let scope: String?
    public let originalName: String
    /// Nil when the entry can't be imported; see `unsupportedReason`.
    public let config: ServerConfig?
    public let unsupportedReason: String?
}

/// Finds MCP servers configured in Claude Desktop, Claude Code and Cursor.
public enum ConfigImporter {
    public static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ImportCandidate] {
        var found: [ImportCandidate] = []
        if let config = read(home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json")) {
            found += parse(config["mcpServers"], source: .claudeDesktop, scope: nil)
        }
        if let config = read(home.appending(path: ".claude.json")) {
            found += parse(config["mcpServers"], source: .claudeCode, scope: nil)
            if case .object(let projects)? = config["projects"] {
                for (path, project) in projects.sorted(by: { $0.key < $1.key }) {
                    found += parse(project["mcpServers"], source: .claudeCode, scope: path)
                }
            }
        }
        if let config = read(home.appending(path: ".cursor/mcp.json")) {
            found += parse(config["mcpServers"], source: .cursor, scope: nil)
        }
        return found
    }

    static func read(_ url: URL) -> JSONValue? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONValue.parse(data)
    }

    static func parse(_ servers: JSONValue?, source: ImportCandidate.Source, scope: String?) -> [ImportCandidate] {
        guard case .object(let entries)? = servers else { return [] }
        return entries.sorted(by: { $0.key < $1.key }).map { name, entry in
            let type = entry["type"]?.stringValue ?? (entry["url"] != nil ? "http" : "stdio")
            guard type == "stdio", let command = entry["command"]?.stringValue, !command.isEmpty else {
                return ImportCandidate(
                    source: source, scope: scope, originalName: name, config: nil,
                    unsupportedReason: type == "stdio" ? "No command" : "\(type.uppercased()) servers aren't supported yet"
                )
            }
            var args: [String] = []
            if case .array(let raw)? = entry["args"] { args = raw.compactMap(\.stringValue) }
            var env: [String: String] = [:]
            if case .object(let raw)? = entry["env"] { env = raw.compactMapValues(\.stringValue) }
            let config = ServerConfig(name: ServerConfig.slug(name), command: command, args: args, env: env)
            return ImportCandidate(source: source, scope: scope, originalName: name, config: config, unsupportedReason: nil)
        }
    }
}
