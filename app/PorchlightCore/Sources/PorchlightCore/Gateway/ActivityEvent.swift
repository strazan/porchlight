import Foundation

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
