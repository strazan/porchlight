import Foundation

/// Receives a server's progress notifications for one request.
public typealias ProgressSink = @Sendable (JSONValue) async -> Void

/// Something that answers MCP messages. `StreamableHTTP` puts it on the wire.
protocol MCPEndpoint: Sendable {
    /// Answers a request. The response must carry the request's id.
    func call(_ request: JSONValue, onProgress: ProgressSink?) async -> JSONValue
    func notify(_ notification: JSONValue) async
}
