import Foundation

public enum UpstreamStatus: Sendable, Equatable {
    case idle
    case starting
    case running
    case failed(String)
}

/// One local MCP server, whatever its transport, shared by every client that reaches it.
///
/// Porchlight performs the `initialize` handshake itself and answers clients' `initialize`
/// from that result. Responses come back with a null id; the caller restores the client's.
public protocol Upstream: Actor {
    nonisolated var name: String { get }

    /// The server's `initialize` response (with a null id), connecting first if needed.
    func initialize() async -> JSONValue
    /// The server's `initialize` result if it's connected, without connecting.
    var handshake: JSONValue? { get }
    /// Sends a request and returns the server's response, with a null id.
    func request(_ message: JSONValue, onProgress: ProgressSink?) async -> JSONValue
    func notify(_ message: JSONValue) async
    func stop() async
}

extension Upstream {
    /// The capabilities the server declared, or nil if it couldn't be reached.
    public func capabilities() async -> JSONValue? {
        await initialize()["result"]?["capabilities"]
    }

    public func request(_ message: JSONValue) async -> JSONValue {
        await request(message, onProgress: nil)
    }
}
