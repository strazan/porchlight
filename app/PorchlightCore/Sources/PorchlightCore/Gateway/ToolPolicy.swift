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

    public init(defaultPermission: Default = .askForChanges, overrides: [String: ToolPermission] = [:]) {
        self.defaultPermission = defaultPermission
        self.overrides = overrides
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
    public let clientName: String
    public let server: String
    public let tool: String
    /// The tool's title, if it has one.
    public let title: String?
    public let arguments: JSONValue

    public init(clientName: String, server: String, tool: String, title: String?, arguments: JSONValue) {
        self.clientName = clientName
        self.server = server
        self.tool = tool
        self.title = title
        self.arguments = arguments
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
        let name = decode("porchlight-client-name")
        self.init(id: decode("porchlight-client-id"), name: name.isEmpty ? Self.unknown.name : name)
    }
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

    public init(date: Date, client: ClientIdentity, server: String?, method: String, tool: String?, duration: Duration, outcome: Outcome) {
        self.date = date
        self.client = client
        self.server = server
        self.method = method
        self.tool = tool
        self.duration = duration
        self.outcome = outcome
    }
}
