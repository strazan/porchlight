import Foundation

/// An app asking to connect through the relay, awaiting the owner's decision.
public struct PairingRequest: Sendable, Identifiable, Equatable {
    public let id: String
    /// Also shown on the app's consent page, so the owner can match the two.
    public let code: String
    /// The app's OAuth client ID.
    public let clientID: String
    public let clientName: String
    /// The app's verified domain (for apps identified by a Client ID Metadata Document).
    public let clientDomain: String?
    /// Where the tokens will be sent.
    public let redirectHost: String
    /// The tokens go to an app on the owner's Mac.
    public let loopback: Bool

    public init(id: String, code: String, clientID: String, clientName: String, clientDomain: String?, redirectHost: String, loopback: Bool) {
        self.id = id
        self.code = code
        self.clientID = clientID
        self.clientName = clientName.displayName()
        self.clientDomain = clientDomain.map { $0.displayName(limit: 253) }
        self.redirectHost = redirectHost
        self.loopback = loopback
    }

    /// `482 913`
    public var formattedCode: String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }
}

/// An app's connection: one OAuth grant. One app can have several.
public struct PairedClient: Sendable, Identifiable, Equatable {
    /// The grant's id, used to revoke it.
    public let id: String
    public let clientID: String
    public let clientName: String
    public let clientDomain: String?
    public let createdAt: Date

    public init(id: String, clientID: String, clientName: String, clientDomain: String?, createdAt: Date) {
        self.id = id
        self.clientID = clientID
        self.clientName = clientName.displayName()
        self.clientDomain = clientDomain.map { $0.displayName(limit: 253) }
        self.createdAt = createdAt
    }
}

/// A request an app made while the Mac was offline, saved by the relay, still sealed.
public struct QueuedRequest: Sendable, Equatable {
    public let id: String
    public let clientID: String
    public let clientName: String
    public let path: String
    public let queuedAt: Date
    public let sealed: Data

    public init(id: String, clientID: String, clientName: String, path: String, queuedAt: Date, sealed: Data) {
        self.id = id
        self.clientID = clientID
        self.clientName = clientName.displayName()
        self.path = path
        self.queuedAt = queuedAt
        self.sealed = sealed
    }
}

/// Things the relay tells the Mac, other than tunneled requests.
public enum RelayEvent: Sendable {
    case pairingRequested(PairingRequest)
    case clientsChanged([PairedClient])
    /// A request saved while the Mac was offline has run (or couldn't).
    case queuedFinished(QueuedRequest, QueuedOutcome)
}

/// How a queued request went, for the app to sum up.
public enum QueuedOutcome: Sendable, Equatable {
    case ran
    /// Denied, blocked, or the tool reported an error.
    case failed
    /// It couldn't be opened, e.g. sealed to this Mac's previous key.
    case unreadable
}
