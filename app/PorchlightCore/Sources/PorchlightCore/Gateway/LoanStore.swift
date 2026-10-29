import Foundation

/// One approved connection lent to a person. Server access is an explicit snapshot,
/// so adding a server later never silently shares it.
public struct Loan: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let borrower: String
    public let servers: Set<String>
    public let expiresAt: Date
    /// Server name → explicitly allowed tool names. Missing entries grant nothing.
    public let allowedTools: [String: Set<String>]

    public init(id: String, borrower: String, servers: Set<String>, expiresAt: Date, allowedTools: [String: Set<String>] = [:]) {
        self.id = id
        self.borrower = borrower.displayName()
        self.servers = servers
        self.expiresAt = expiresAt
        self.allowedTools = allowedTools.filter { servers.contains($0.key) }
    }

    private enum CodingKeys: String, CodingKey { case id, borrower, servers, expiresAt, allowedTools }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  borrower: try values.decode(String.self, forKey: .borrower),
                  servers: try values.decode(Set<String>.self, forKey: .servers),
                  expiresAt: try values.decode(Date.self, forKey: .expiresAt),
                  allowedTools: try values.decodeIfPresent([String: Set<String>].self, forKey: .allowedTools) ?? [:])
    }

    public var toolCount: Int { allowedTools.values.reduce(0) { $0 + $1.count } }

}

/// Local permission records; OAuth credentials continue to live at the relay.
public struct LoanStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> [Loan] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Loan].self, from: Data(contentsOf: url))
    }

    public func save(_ loans: [Loan]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(loans).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
