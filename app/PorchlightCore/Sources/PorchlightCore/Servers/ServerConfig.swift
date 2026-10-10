import Foundation

/// A local MCP server Porchlight runs. Same shape as Claude Desktop's `mcpServers` entries.
public struct ServerConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// URL-safe and unique: used in `/s/<name>/mcp` and as the tool-name prefix.
    public var name: String
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.enabled = enabled
    }

    public var commandLine: [String] { [command] + args }

    /// The command as one shell-style line, for display and editing.
    public var commandLineString: String {
        get { commandLine.map(shellQuoted).joined(separator: " ") }
        set {
            let parts = splitCommandLine(newValue)
            command = parts.first ?? ""
            args = Array(parts.dropFirst())
        }
    }

    /// Lowercase letters, digits and single hyphens; at most 32 characters.
    public static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) != nil && name.count <= 32
    }

    /// Turns anything (e.g. a name from another app's config) into a valid name.
    public static func slug(_ raw: String) -> String {
        var slug = ""
        for ch in raw.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                slug.append(ch)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        slug = String(slug.prefix(32))
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "server" : slug
    }

    /// A name guessed from a command line, e.g. `filesystem` for
    /// `npx -y @modelcontextprotocol/server-filesystem ~/Docs`.
    public static func suggestedName(for commandLine: [String]) -> String {
        let runners: Set<String> = ["npx", "bunx", "pnpx", "uvx", "pipx", "docker", "node", "python", "python3", "deno"]
        let candidates = commandLine.enumerated().filter { index, arg in
            !arg.hasPrefix("-") && !(index == 0 && runners.contains(arg)) && !["run", "dlx"].contains(arg)
        }
        guard let package = candidates.first?.element else { return "" }
        // Last meaningful path component, minus the usual MCP prefixes and suffixes.
        for component in package.split(separator: "/").reversed() {
            var name = String(component.split(separator: "@").first ?? component)
            for prefix in ["mcp-server-", "server-", "mcp-"] where name.hasPrefix(prefix) {
                name.removeFirst(prefix.count)
            }
            for suffix in ["-mcp-server", "-mcp", "-server"] where name.hasSuffix(suffix) {
                name.removeLast(suffix.count)
            }
            if !name.isEmpty, name != "mcp" { return slug(name) }
        }
        return ""
    }

    /// `base`, or `base-2`, `base-3`… whichever isn't taken.
    public static func uniqueName(_ base: String, taken: Set<String>) -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}

/// Quotes an argument for display only if it needs it.
public func shellQuoted(_ arg: String) -> String {
    let safe = arg.allSatisfy { $0.isLetter || $0.isNumber || "-_./:@=+,~%".contains($0) }
    if safe, !arg.isEmpty { return arg }
    return "'" + arg.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

/// Reads and writes the server list as JSON.
public struct ServerStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/Porchlight/servers.json`
    public static var standard: ServerStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ServerStore(url: support.appending(path: "Porchlight/servers.json"))
    }

    public func load() -> [ServerConfig]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([ServerConfig].self, from: data)
    }

    public func save(_ servers: [ServerConfig]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // May hold API keys in `env`: readable by this user only.
        try encoder.encode(servers).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
