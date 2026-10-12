import Foundation

/// Serves one upstream as-is, at `/mcp/<name>`.
struct PassthroughEndpoint: MCPEndpoint {
    let upstream: any Upstream

    func call(_ request: JSONValue, onProgress: ProgressSink?) async -> JSONValue {
        var response = request.rpcMethod == "initialize"
            ? await upstream.initialize()
            : await upstream.request(request, onProgress: onProgress)
        response["id"] = request.rpcID ?? .null
        return response
    }

    func notify(_ notification: JSONValue) async {
        // Porchlight already completed the handshake with the child.
        guard notification.rpcMethod != "notifications/initialized" else { return }
        await upstream.notify(notification)
    }
}
