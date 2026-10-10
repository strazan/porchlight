import Foundation

/// Serves one upstream as-is, at `/mcp/<name>`.
public struct PassthroughEndpoint: MCPEndpoint {
    let upstream: any Upstream

    public init(upstream: any Upstream) {
        self.upstream = upstream
    }

    public func call(_ request: JSONValue, onProgress: ProgressSink?) async -> JSONValue {
        var response = request.rpcMethod == "initialize"
            ? await upstream.initialize()
            : await upstream.request(request, onProgress: onProgress)
        response["id"] = request.rpcID ?? .null
        return response
    }

    public func notify(_ notification: JSONValue) async {
        // Porchlight already completed the handshake with the child.
        guard notification.rpcMethod != "notifications/initialized" else { return }
        await upstream.notify(notification)
    }
}
