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

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultPermission = try container.decode(Default.self, forKey: .defaultPermission)
        overrides = try container.decode([String: ToolPermission].self, forKey: .overrides)
        // Saved before offline queueing existed.
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

/// The owner's answer when a tool call needs approval.
public enum ToolApproval: Sendable, Equatable {
    case allowOnce
    /// Allow, and stop asking for this tool. The app persists the override.
    case allowAlways
    case deny
}

/// A tool call waiting for the owner's approval.
public struct ToolApprovalRequest: Sendable, Identifiable, Equatable {
    public let id = UUID()
    /// Empty for requests that didn't come through the relay's OAuth.
    public let clientID: String
    public let clientName: String
    public let server: String
    public let tool: String
    /// The tool's title, if it has one.
    public let title: String?
    public let arguments: JSONValue
    /// When the app made the call, for one saved while the Mac was offline.
    public let queuedAt: Date?

    public init(clientID: String = "", clientName: String, server: String, tool: String, title: String?, arguments: JSONValue, queuedAt: Date? = nil) {
        self.clientID = clientID
        self.clientName = clientName
        self.server = server
        self.tool = tool
        self.title = title
        self.arguments = arguments
        self.queuedAt = queuedAt
    }
}

/// Who sent a request, as the relay identified them.
public struct ClientIdentity: Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// Requests that didn't come through the relay's OAuth (e.g. local testing).
    public static let unknown = ClientIdentity(id: "", name: "Unknown app")

    init(headers request: HTTPRequest) {
        let decode = { (name: String) in request.header(name).flatMap { $0.removingPercentEncoding } ?? "" }
        let name = displayName(decode("porchlight-client-name"))
        self.init(id: decode("porchlight-client-id"), name: name.isEmpty ? Self.unknown.name : name)
    }
}

/// Apps name themselves when they register. Keeps a name to one plain line, so it can't fake a
/// second line ("Published by…") or reorder text with direction overrides.
public func displayName(_ name: String, limit: Int = 80) -> String {
    var plain = ""
    var space = false
    for scalar in name.unicodeScalars {
        // Invisible formatting (direction overrides, zero-width spaces) goes; breaks become spaces.
        if scalar.properties.generalCategory == .format { continue }
        if scalar.properties.generalCategory == .control || scalar.properties.isWhitespace {
            space = !plain.isEmpty
        } else {
            if space { plain.unicodeScalars.append(" ") }
            plain.unicodeScalars.append(scalar)
            space = false
        }
    }
    return plain.count > limit ? String(plain.prefix(limit)) : plain
}

/// One request through Porchlight, for the activity log.
public struct ActivityEvent: Sendable, Identifiable {
    public enum Outcome: Sendable, Equatable {
        case ok
        case error(String)
        /// Blocked by a permission, or declined by the owner.
        case denied(String)
    }

    public let id = UUID()
    public let date: Date
    public let client: ClientIdentity
    /// The server the request was for, when it was for one (a tool call, or a per-server endpoint).
    public let server: String?
    public let method: String
    public let tool: String?
    public let duration: Duration
    public let outcome: Outcome
    /// When the app made the request, for one saved while the Mac was offline.
    public let queuedAt: Date?

    public init(date: Date, client: ClientIdentity, server: String?, method: String, tool: String?, duration: Duration, outcome: Outcome, queuedAt: Date? = nil) {
        self.date = date
        self.client = client
        self.server = server
        self.method = method
        self.tool = tool
        self.duration = duration
        self.outcome = outcome
        self.queuedAt = queuedAt
    }
}
