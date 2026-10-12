import Foundation

public enum ToolPermission: String, Codable, Sendable, CaseIterable {
    case allow
    case ask
    case deny
}

/// What a server's tools may do without asking, and per-tool exceptions.
public struct ToolPolicy: Codable, Sendable, Hashable {
    public enum Default: String, Codable, Sendable, CaseIterable {
        case allowAll
        /// Tools that declare themselves read-only run; anything else asks first.
        case askForChanges
        case askAll
    }

    public var defaultPermission: Default
    /// Tool name (as the server names it) → permission.
    public var overrides: [String: ToolPermission]
    /// Tool name → whether calls made while the Mac is offline are saved for later, where
    /// the owner changed it from the default (see `queuesOffline`).
    public var offline: [String: Bool]

    public init(defaultPermission: Default = .askForChanges, overrides: [String: ToolPermission] = [:], offline: [String: Bool] = [:]) {
        self.defaultPermission = defaultPermission
        self.overrides = overrides
        self.offline = offline
    }

    private enum CodingKeys: String, CodingKey {
        case defaultPermission, overrides, offline
    }

    /// Every field is optional, for server lists written by hand (see `porchlight-cli --config`).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultPermission = try container.decodeIfPresent(Default.self, forKey: .defaultPermission) ?? .askForChanges
        overrides = try container.decodeIfPresent([String: ToolPermission].self, forKey: .overrides) ?? [:]
        offline = try container.decodeIfPresent([String: Bool].self, forKey: .offline) ?? [:]
    }

    /// Whether a call to `tool` made while the Mac is offline is saved and run when it's back.
    /// By default only tools that add without changing or deleting anything: their server says
    /// they're neither read-only (nothing to wait for) nor destructive. Blocked tools never queue.
    public func queuesOffline(_ tool: String, readOnly: Bool, destructive: Bool) -> Bool {
        guard !readOnly, permission(for: tool, readOnly: readOnly) != .deny else { return false }
        return offline[tool] ?? !destructive
    }

    /// `readOnly` is the tool's `readOnlyHint` annotation.
    public func permission(for tool: String, readOnly: Bool) -> ToolPermission {
        overrides[tool] ?? defaultPermission(readOnly: readOnly)
    }

    /// What a tool without an override gets.
    public func defaultPermission(readOnly: Bool) -> ToolPermission {
        switch defaultPermission {
        case .allowAll: .allow
        case .askAll: .ask
        case .askForChanges: readOnly ? .allow : .ask
        }
    }
}
