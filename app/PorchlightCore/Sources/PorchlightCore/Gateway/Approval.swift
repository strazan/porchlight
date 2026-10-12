import Foundation

/// The owner's answer when a tool call needs approval.
public enum ToolApproval: Sendable, Equatable {
    case allowOnce
    /// Allow, and stop asking for this tool. The router allows it from then on; the app also
    /// saves it in the server's settings.
    case allowAlways
    case deny
}

/// A tool call waiting for the owner's approval.
public struct ToolApprovalRequest: Sendable, Identifiable, Equatable {
    public let id = UUID()
    public let client: ClientIdentity
    public let server: String
    public let tool: String
    /// The tool's title, if it has one.
    public let title: String?
    public let arguments: JSONValue
    /// When the app made the call, for one saved while the Mac was offline.
    public let queuedAt: Date?

    public init(client: ClientIdentity, server: String, tool: String, title: String?, arguments: JSONValue, queuedAt: Date? = nil) {
        self.client = client
        self.server = server
        self.tool = tool
        self.title = title
        self.arguments = arguments
        self.queuedAt = queuedAt
    }
}
