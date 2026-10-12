import Foundation

public enum UpstreamStatus: Sendable, Equatable {
    case idle
    case starting
    case running
    case failed(String)
}

typealias UpstreamStatusSink = @Sendable (UpstreamStatus) -> Void

/// One local MCP server, whatever its transport, shared by every app that reaches it.
///
/// Porchlight performs the `initialize` handshake itself and answers apps' `initialize`
/// from that result. Responses come back with a null id; the caller restores the app's.
protocol Upstream: Actor {
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
    func capabilities() async -> JSONValue? {
        await initialize()["result"]?["capabilities"]
    }

    func request(_ message: JSONValue) async -> JSONValue {
        await request(message, onProgress: nil)
    }
}

extension ServerConfig {
    /// The server, ready to start on first use. A config that isn't runnable fails then, with
    /// its status saying why.
    func makeUpstream(environment: [String: String], log: @escaping LogSink, onStatus: @escaping UpstreamStatusSink) -> any Upstream {
        switch transport {
        case .stdio:
            StdioUpstream(
                name: name, command: commandLine, environment: environment.merging(env) { _, own in own },
                log: log, onStatus: onStatus
            )
        case .http:
            HTTPUpstream(name: name, url: URL(string: url), headers: headers, log: log, onStatus: onStatus)
        }
    }
}

enum UpstreamError: LocalizedError {
    case initializeFailed(String)
    case invalidURL
    case noResponse
    case sessionExpired
    case status(Int, String)

    var errorDescription: String? {
        switch self {
        case .initializeFailed(let message): "initialize failed: \(message)"
        case .invalidURL: "The server's URL isn't valid"
        case .noResponse: "The server closed the connection without answering"
        case .sessionExpired: "The server no longer knows this session"
        case .status(401, _), .status(403, _): "The server refused the request (check the Authorization header)"
        case .status(let code, let body): body.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(body)"
        }
    }
}
