import Foundation

/// A local MCP server Porchlight serves: a command it runs (stdio), or a server already
/// listening on this machine (Streamable HTTP). Same shape as the `mcpServers` entries in
/// Claude Desktop and Claude Code configs.
public struct ServerConfig: Codable, Sendable, Hashable, Identifiable {
    public enum Transport: String, Codable, Sendable, Hashable, CaseIterable {
        case stdio
        case http
    }

    public var id: UUID
    /// URL-safe and unique: used in `/mcp/<name>` and as the tool-name prefix.
    public var name: String
    public var transport: Transport
    // stdio
    public var command: String
    public var args: [String]
    public var env: [String: String]
    // http
    public var url: String
    public var headers: [String: String]
    public var enabled: Bool
    public var toolPolicy: ToolPolicy

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
        transport = .stdio
        self.command = command
        self.args = args
        self.env = env
        url = ""
        headers = [:]
        self.enabled = enabled
        toolPolicy = ToolPolicy()
    }

    public init(id: UUID = UUID(), name: String, url: String, headers: [String: String] = [:], enabled: Bool = true) {
        self.id = id
        self.name = name
        transport = .http
        command = ""
        args = []
        env = [:]
        self.url = url
        self.headers = headers
        self.enabled = enabled
        toolPolicy = ToolPolicy()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, transport, command, args, env, url, headers, enabled, toolPolicy
    }

    // Lists saved before HTTP servers existed have no transport, url or headers.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        transport = try c.decodeIfPresent(Transport.self, forKey: .transport) ?? .stdio
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        toolPolicy = try c.decodeIfPresent(ToolPolicy.self, forKey: .toolPolicy) ?? ToolPolicy()
    }

    public var commandLine: [String] { [command] + args }

    /// What the server is, in one line: its command or its URL.
    public var summary: String {
        transport == .http ? url : commandLineString
    }

    /// Whether the transport-specific fields are filled in sensibly.
    public var isRunnable: Bool {
        switch transport {
        case .stdio: !command.isEmpty
        case .http: URL(string: url).map { ["http", "https"].contains($0.scheme) && $0.host() != nil } ?? false
        }
    }

    /// Whether two configs describe the same server, ignoring name, on/off and tool policy
    /// (none of which need the server restarted).
    public func sameServer(as other: ServerConfig) -> Bool {
        transport == other.transport && commandLine == other.commandLine && env == other.env
            && url == other.url && headers == other.headers
    }

    /// The command as one shell-style line, for display and editing.
    public var commandLineString: String {
        get { command.isEmpty && args.isEmpty ? "" : commandLine.map(shellQuoted).joined(separator: " ") }
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

// MARK: - Headers

extension ServerConfig {
    /// `Authorization: Bearer <token>`, the usual way local servers take an API key.
    public var bearerToken: String {
        get {
            guard let value = headers["Authorization"], value.lowercased().hasPrefix("bearer ") else { return "" }
            return String(value.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        }
        set {
            let token = Self.bearerToken(from: newValue)
            headers["Authorization"] = token.isEmpty ? nil : "Bearer \(token)"
        }
    }

    /// Accepts what people paste for an API key: the key itself, `Bearer <key>`, or a
    /// whole header line such as `Authorization: Bearer <key>` or `"Authorization": "Bearer <key>",`.
    public static func bearerToken(from pasted: String) -> String {
        var token = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if let header = parseHeader(token), header.name.lowercased() == "authorization" { token = header.value }
        if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst("bearer ".count)) }
        return token.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"',")))
    }

    /// Parses a header line: `Name: value`, or the JSON form `"Name": "value"`.
    public static func parseHeader(_ line: String) -> (name: String, value: String)? {
        let pattern = /^\s*"?([A-Za-z0-9!#$%&'*+.^_`|~-]+)"?\s*:\s*"?(.*?)"?\s*,?\s*$/
        guard let match = line.wholeMatch(of: pattern) else { return nil }
        return (String(match.1), String(match.2))
    }

    /// An HTTP header name: a token of letters, digits and a few symbols, no spaces or colons.
    public static func isValidHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+.^_`|~-".contains($0)) }
    }

    /// Fixes headers where a whole `Name: value` line ended up as the name.
    public func repairingHeaders() -> ServerConfig {
        var repaired = self
        repaired.headers = [:]
        for (name, value) in headers {
            if !Self.isValidHeaderName(name), value.isEmpty, let header = Self.parseHeader(name) {
                repaired.headers[header.name] = header.value
            } else {
                repaired.headers[name] = value
            }
        }
        return repaired
    }
}

/// Quotes an argument for display only if it needs it.
/// A command line for logs, with what looks like a credential masked: the value after a flag
/// like `--api-key`, `--token=…`, and the query of any URL.
public func loggableCommandLine(_ command: [String]) -> String {
    let sensitive = /(?i)(key|token|secret|passw|auth|credential|bearer)/
    var masked: [String] = []
    var maskNext = false
    for arg in command {
        defer { maskNext = arg.hasPrefix("-") && !arg.contains("=") && arg.contains(sensitive) }
        if maskNext {
            masked.append("***")
        } else if arg.hasPrefix("-"), let eq = arg.firstIndex(of: "="), arg[..<eq].contains(sensitive) {
            masked.append(String(arg[...eq]) + "***")
        } else {
            masked.append(shellQuoted(loggableURL(arg)))
        }
    }
    return masked.joined(separator: " ")
}

/// A URL for logs, without its query (where tokens often go) or password.
public func loggableURL(_ string: String) -> String {
    guard var parts = URLComponents(string: string), parts.scheme != nil, parts.host != nil,
          parts.query != nil || parts.password != nil
    else { return string }
    if parts.query != nil { parts.percentEncodedQuery = "***" }
    if parts.password != nil { parts.percentEncodedPassword = "***" }
    return parts.string ?? string
}

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
