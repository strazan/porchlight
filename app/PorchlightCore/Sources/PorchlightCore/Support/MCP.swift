import Foundation

/// The MCP versions Porchlight speaks, and the handshake it opens with each server.
enum MCP {
    /// Newest first. A client asking for one of these gets it; others get `preferredVersion`.
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    /// What Porchlight asks its servers for.
    static let preferredVersion = "2025-06-18"

    static var initializeRequest: JSONValue {
        .rpcRequest("initialize", params: [
            "protocolVersion": .string(preferredVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("porchlight"), "version": .string(Porchlight.version)]),
        ])
    }

    static let initializedNotification = JSONValue.rpcRequest("notifications/initialized")
}
