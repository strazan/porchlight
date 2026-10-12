import Foundation

/// The server side of MCP's Streamable HTTP transport, for requests arriving via the relay.
///
/// `tools/call` is answered as an SSE stream with keepalives, so slow tools don't hit the
/// relay's start timeout and progress notifications reach the caller. Everything else is
/// plain JSON. There is no GET stream or session handling yet.
enum StreamableHTTP {
    static let keepaliveInterval: Duration = .seconds(15)

    static func serve(_ request: HTTPRequest, _ responder: HTTPResponder, endpoint: some MCPEndpoint) async {
        guard request.method == "POST" else {
            return await responder.respond(405, [("allow", "POST")])
        }
        guard let message = try? JSONValue.parse(request.body) else {
            return await respondJSON(responder, 400, .rpcError(id: nil, code: .parseError, message: "Parse error"))
        }

        if case .array(let batch) = message {
            var responses: [JSONValue] = []
            for item in batch {
                if let response = await dispatch(item, endpoint) { responses.append(response) }
            }
            return responses.isEmpty
                ? await responder.respond(202)
                : await respondJSON(responder, 200, .array(responses))
        }
        if message.isRequest, message.rpcMethod == "tools/call",
           request.header("accept")?.contains("text/event-stream") == true {
            return await stream(message, responder, endpoint)
        }
        if let response = await dispatch(message, endpoint) {
            await respondJSON(responder, 200, response)
        } else {
            await responder.respond(202)
        }
    }

    /// Returns the response for a request, or nil for notifications and client responses.
    private static func dispatch(_ message: JSONValue, _ endpoint: some MCPEndpoint) async -> JSONValue? {
        if message.isRequest { return await endpoint.call(message, onProgress: nil) }
        if message.isNotification { await endpoint.notify(message) }
        // Responses to server-initiated requests: none are sent to clients yet.
        return nil
    }

    private static func stream(_ message: JSONValue, _ responder: HTTPResponder, _ endpoint: some MCPEndpoint) async {
        await responder.start(200, [("content-type", "text/event-stream"), ("cache-control", "no-cache")])
        let keepalive = Task {
            while true {
                try await Task.sleep(for: keepaliveInterval)
                await responder.chunk(Data(": keepalive\n\n".utf8))
            }
        }
        let response = await endpoint.call(message) { progress in
            await responder.chunk(sseEvent(progress))
        }
        keepalive.cancel()
        _ = await keepalive.result
        await responder.chunk(sseEvent(response))
        await responder.end()
    }

    static func respondJSON(_ responder: HTTPResponder, _ status: Int, _ body: JSONValue) async {
        await responder.respond(status, [("content-type", "application/json")], body: body.serialized())
    }

    static func sseEvent(_ message: JSONValue) -> Data {
        Data("event: message\ndata: ".utf8) + message.serialized() + Data("\n\n".utf8)
    }
}
