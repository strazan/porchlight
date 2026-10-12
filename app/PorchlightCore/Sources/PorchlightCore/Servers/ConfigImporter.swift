import Foundation

/// A server found in another app's MCP config.
public struct ImportCandidate: Sendable, Identifiable, Hashable {
    public enum Source: String, Sendable, Hashable, CaseIterable {
        case claudeDesktop = "Claude Desktop"
        case claudeExtensions = "Claude Desktop Extensions"
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
    /// For a Claude Desktop extension: its folder, copied into Porchlight's own when imported
    /// so it keeps working if the extension is removed from Claude Desktop.
    public let bundle: ExtensionBundle?

    public init(source: Source, scope: String?, originalName: String, config: ServerConfig?, unsupportedReason: String?, bundle: ExtensionBundle? = nil) {
        self.source = source
        self.scope = scope
        self.originalName = originalName
        self.config = config
        self.unsupportedReason = unsupportedReason
        self.bundle = bundle
    }
}

/// Where an extension's files are copied from and to. The candidate's config already points
/// at `destination`.
public struct ExtensionBundle: Sendable, Hashable {
    public let source: URL
    public let destination: URL

    public init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }
}

/// Finds MCP servers configured in Claude Desktop (including its extensions), Claude Code
/// and Cursor.
public enum ConfigImporter {
    public static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ImportCandidate] {
        var found: [ImportCandidate] = []
        let claude = home.appending(path: "Library/Application Support/Claude")
        if let config = read(claude.appending(path: "claude_desktop_config.json")) {
            found += parse(config["mcpServers"], source: .claudeDesktop, scope: nil)
        }
        found += extensions(
            in: claude.appending(path: "Claude Extensions"),
            settings: claude.appending(path: "Claude Extensions Settings"),
            copyingTo: extensionsDirectory(home: home),
            home: home
        )
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

    /// Where imported extensions live: `~/Library/Application Support/Porchlight/Extensions`.
    static func extensionsDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Application Support/Porchlight/Extensions")
    }

    /// Copies an extension candidate's files to where its config expects them, replacing an
    /// earlier copy. Does nothing for other candidates.
    public static func install(_ candidate: ImportCandidate) throws {
        guard let bundle = candidate.bundle else { return }
        let files = FileManager.default
        try files.createDirectory(at: bundle.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: bundle.destination.path) { try files.removeItem(at: bundle.destination) }
        try files.copyItem(at: bundle.source, to: bundle.destination)
    }

    /// Claude Desktop extensions (MCP Bundles): each folder holds a `manifest.json` whose
    /// `server.mcp_config` says how to start it, with `${…}` placeholders.
    static func extensions(in folder: URL, settings: URL, copyingTo destinationRoot: URL, home: URL) -> [ImportCandidate] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { source in
            guard let manifest = read(source.appending(path: "manifest.json")) else { return nil }
            let id = source.lastPathComponent
            let destination = destinationRoot.appending(path: id)
            let name = manifest["display_name"]?.stringValue ?? manifest["name"]?.stringValue ?? id
            let unsupported = { (reason: String) in
                ImportCandidate(source: .claudeExtensions, scope: nil, originalName: name, config: nil, unsupportedReason: reason)
            }
            guard var launch = manifest["server"]?["mcp_config"] else { return unsupported("No server to run") }
            if let mac = launch["platform_overrides"]?["darwin"], case .object(let overrides) = mac {
                for (key, value) in overrides { launch[key] = value }
            }
            guard let command = launch["command"]?.stringValue, !command.isEmpty else { return unsupported("No command") }

            // Settings the user filled in when installing it, then the manifest's defaults.
            var values: [String: JSONValue] = [:]
            if case .object(let fields)? = manifest["user_config"] {
                for (key, field) in fields { if let value = field["default"] { values[key] = value } }
            }
            if case .object(let saved)? = read(settings.appending(path: "\(id).json"))?["userConfig"] {
                values.merge(saved) { $1 }
            }
            let resolver = PlaceholderResolver(directory: destination.path, home: home.path, values: values)

            do {
                let command = try resolver.resolve(command)
                var args: [String] = []
                if case .array(let raw)? = launch["args"] {
                    for arg in raw.compactMap(\.stringValue) { args += try resolver.expand(arg) }
                }
                var env: [String: String] = [:]
                if case .object(let raw)? = launch["env"] {
                    for (key, value) in raw { if let value = value.stringValue { env[key] = try resolver.resolve(value) } }
                }
                let slug = ServerConfig.slug(manifest["name"]?.stringValue ?? name)
                let config = ServerConfig(name: slug, command: command, args: args, env: env)
                return ImportCandidate(
                    source: .claudeExtensions, scope: nil, originalName: name, config: config, unsupportedReason: nil,
                    bundle: ExtensionBundle(source: source, destination: destination)
                )
            } catch PlaceholderResolver.Missing.setting(let key) {
                let title = manifest["user_config"]?[key]?["title"]?.stringValue ?? key
                return unsupported("Needs “\(title)”, which Claude Desktop keeps to itself: add it with + instead")
            } catch {
                return unsupported("Can't read its launch settings")
            }
        }
    }

    static func read(_ url: URL) -> JSONValue? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONValue.parse(data)
    }

    static func parse(_ servers: JSONValue?, source: ImportCandidate.Source, scope: String?) -> [ImportCandidate] {
        guard case .object(let entries)? = servers else { return [] }
        return entries.sorted(by: { $0.key < $1.key }).map { name, entry in
            let type = entry["type"]?.stringValue ?? (entry["url"] != nil ? "http" : "stdio")
            let unsupported = { (reason: String) in
                ImportCandidate(source: source, scope: scope, originalName: name, config: nil, unsupportedReason: reason)
            }
            if type == "http" || type == "streamable-http" {
                guard let url = entry["url"]?.stringValue, let host = URL(string: url)?.host() else { return unsupported("No URL") }
                // A server on the internet doesn't need Porchlight: cloud agents can reach it directly.
                guard Hosts.isLocal(host) else { return unsupported("Remote server: cloud agents can reach it directly") }
                var headers: [String: String] = [:]
                if case .object(let raw)? = entry["headers"] { headers = raw.compactMapValues(\.stringValue) }
                let config = ServerConfig(name: ServerConfig.slug(name), url: url, headers: headers)
                return ImportCandidate(source: source, scope: scope, originalName: name, config: config, unsupportedReason: nil)
            }
            guard type == "stdio" else { return unsupported("\(type.uppercased()) servers aren't supported yet") }
            guard let command = entry["command"]?.stringValue, !command.isEmpty else { return unsupported("No command") }
            var args: [String] = []
            if case .array(let raw)? = entry["args"] { args = raw.compactMap(\.stringValue) }
            var env: [String: String] = [:]
            if case .object(let raw)? = entry["env"] { env = raw.compactMapValues(\.stringValue) }
            let config = ServerConfig(name: ServerConfig.slug(name), command: command, args: args, env: env)
            return ImportCandidate(source: source, scope: scope, originalName: name, config: config, unsupportedReason: nil)
        }
    }
}

/// Fills in an MCP Bundle's `${…}` placeholders.
struct PlaceholderResolver {
    enum Missing: Error { case setting(String) }

    let directory: String
    let home: String
    let values: [String: JSONValue]

    /// An argument that is exactly one list-valued setting becomes one argument per item.
    func expand(_ arg: String) throws -> [String] {
        if arg.hasPrefix("${user_config."), arg.hasSuffix("}"), arg.filter({ $0 == "$" }).count == 1 {
            let key = String(arg.dropFirst("${user_config.".count).dropLast())
            if case .array(let items)? = values[key] { return try items.map { try resolve(text($0, key: key), depth: 1) } }
        }
        return [try resolve(arg)]
    }

    /// `depth` counts settings resolved inside settings, so one that refers to itself ends.
    func resolve(_ text: String, depth: Int = 0) throws -> String {
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: "${"), let end = rest[start.upperBound...].firstIndex(of: "}") {
            result += rest[..<start.lowerBound]
            let name = String(rest[start.upperBound..<end])
            result += try value(of: name, raw: String(rest[start.lowerBound...end]), depth: depth)
            rest = rest[rest.index(after: end)...]
        }
        return result + rest
    }

    private func value(of name: String, raw: String, depth: Int) throws -> String {
        switch name {
        case "__dirname": return directory
        case "HOME": return home
        case "DESKTOP": return home + "/Desktop"
        case "DOCUMENTS": return home + "/Documents"
        case "DOWNLOADS": return home + "/Downloads"
        case "pathSeparator", "/": return "/"
        default:
            guard name.hasPrefix("user_config.") else { return raw }
            let key = String(name.dropFirst("user_config.".count))
            guard let value = values[key], depth < 8 else { throw Missing.setting(key) }
            if case .array(let items) = value {
                return try items.map { try resolve(text($0, key: key), depth: depth + 1) }.joined(separator: ",")
            }
            // Defaults can use placeholders too, like ${HOME}/Documents.
            return try resolve(text(value, key: key), depth: depth + 1)
        }
    }

    private func text(_ value: JSONValue, key: String) throws -> String {
        switch value {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        default: throw Missing.setting(key)
        }
    }
}
