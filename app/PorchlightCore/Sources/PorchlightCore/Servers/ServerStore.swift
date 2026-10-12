import Foundation

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

    /// Nil if there's no list yet. Throws if there is one that can't be read, so it isn't
    /// mistaken for none and overwritten.
    public func load() throws -> [ServerConfig]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode([ServerConfig].self, from: Data(contentsOf: url))
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
