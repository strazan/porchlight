import Foundation

/// Serves one stdio MCP server over Streamable HTTP (the requests arrive via the relay).
///
/// Several cloud clients share one child process, so the bridge:
/// - rewrites request ids to its own (`pl-N`) and maps responses back,
/// - performs `initialize` once and answers later ones from cache,
/// - starts the child lazily and replays the handshake if it restarts.
///
/// `tools/call` is answered as an SSE stream with keepalives, so slow tools don't hit
/// the relay's start timeout, and progress notifications reach the right caller.
public actor StdioBridge: HTTPHandler {
    public let name: String
    private let command: [String]
    private let environment: [String: String]?
    private let log: LogSink

    static let keepaliveInterval: Duration = .seconds(15)

    private var process: StdioProcess?
    private var starting: Task<Void, Error>?
    private var nextID = 0
    private var pending: [String: CheckedContinuation<JSONValue, Never>] = [:]
    private var progressRoutes: [JSONValue: @Sendable (JSONValue) async -> Void] = [:]

    private var initializeParams: JSONValue?
    private var initializeResult: JSONValue?
    private var initializing: Task<JSONValue, Never>?

    public init(name: String, command: [String], environment: [String: String]? = nil, log: @escaping LogSink = stderrLog) {
        self.name = name
        self.command = command
        self.environment = environment
        self.log = log
    }

    public func stop() {
        process?.terminate()
    }

    // MARK: HTTP

    public func handle(_ request: HTTPRequest, _ responder: HTTPResponder) async {
        guard request.route == "/mcp" || request.route == "/s/\(name)/mcp" else {
            return await responder.respond(404, [("content-type", "text/plain")], body: Data("No such server\n".utf8))
        }
        guard request.method == "POST" else {
            // No server-initiated stream (GET) and no sessions to end (DELETE) yet.
            return await responder.respond(405, [("allow", "POST")])
        }
        guard let message = try? JSONValue.parse(request.body) else {
            return await respondJSON(responder, 400, .rpcError(id: nil, code: -32700, message: "Parse error"))
        }

        if case .array(let batch) = message {
            var responses: [JSONValue] = []
            for item in batch {
                if let response = await process(item) { responses.append(response) }
            }
            return responses.isEmpty
                ? await responder.respond(202)
                : await respondJSON(responder, 200, .array(responses))
        }
        if message.isRequest, message.rpcMethod == "tools/call",
           request.header("accept")?.contains("text/event-stream") == true {
            return await streamCall(message, responder)
        }
        if let response = await process(message) {
            await respondJSON(responder, 200, response)
        } else {
            await responder.respond(202)
        }
    }

    private func respondJSON(_ responder: HTTPResponder, _ status: Int, _ body: JSONValue) async {
        await responder.respond(status, [("content-type", "application/json")], body: body.serialized())
    }

    private func streamCall(_ message: JSONValue, _ responder: HTTPResponder) async {
        await responder.start(200, [("content-type", "text/event-stream"), ("cache-control", "no-cache")])
        let keepalive = Task {
            while true {
                try await Task.sleep(for: Self.keepaliveInterval)
                await responder.chunk(Data(": keepalive\n\n".utf8))
            }
        }
        let response = await call(message) { progress in
            await responder.chunk(Self.sseEvent(progress))
        }
        keepalive.cancel()
        _ = await keepalive.result
        await responder.chunk(Self.sseEvent(response))
        await responder.end()
    }

    static func sseEvent(_ message: JSONValue) -> Data {
        Data("event: message\ndata: ".utf8) + message.serialized() + Data("\n\n".utf8)
    }

    // MARK: JSON-RPC

    /// Returns the response for a request, or nil for notifications and client responses.
    private func process(_ message: JSONValue) async -> JSONValue? {
        if message.isRequest { return await call(message, onProgress: nil) }
        // The bridge sends its own `initialized` after the one real handshake.
        if message.isNotification, message.rpcMethod != "notifications/initialized" {
            do {
                try await ensureRunning()
                try process?.send(message)
            } catch {
                log("[\(name)] dropped notification: \(error.localizedDescription)")
            }
        }
        // Responses to server-initiated requests: none are forwarded to clients yet.
        return nil
    }

    private func call(_ message: JSONValue, onProgress: (@Sendable (JSONValue) async -> Void)?) async -> JSONValue {
        let clientID = message.rpcID ?? .null
        var response: JSONValue
        if message.rpcMethod == "initialize" {
            response = await initialize(params: message["params"] ?? .object([:]))
        } else {
            do {
                try await ensureRunning()
            } catch {
                return .rpcError(id: clientID, code: -32603, message: "Could not start \(name): \(error.localizedDescription)")
            }
            let token = message["params"]?["_meta"]?["progressToken"]
            if let token, let onProgress { progressRoutes[token] = onProgress }
            response = await send(message)
            if let token { progressRoutes[token] = nil }
        }
        response["id"] = clientID
        return response
    }

    private func initialize(params: JSONValue) async -> JSONValue {
        if let initializeResult {
            return .object(["jsonrpc": .string("2.0"), "id": .null, "result": initializeResult])
        }
        if let initializing { return await initializing.value }
        let task = Task { await self.performInitialize(params) }
        initializing = task
        let response = await task.value
        initializing = nil
        return response
    }

    private func performInitialize(_ params: JSONValue) async -> JSONValue {
        do {
            try await ensureRunning()
        } catch {
            return .rpcError(id: nil, code: -32603, message: "Could not start \(name): \(error.localizedDescription)")
        }
        let response = await send(.object(["jsonrpc": .string("2.0"), "method": .string("initialize"), "params": params]))
        if let result = response["result"] {
            initializeParams = params
            initializeResult = result
            try? process?.send(Self.initializedNotification)
        }
        return response
    }

    static let initializedNotification: JSONValue = .object([
        "jsonrpc": .string("2.0"), "method": .string("notifications/initialized"),
    ])

    /// Sends a request to the child under a fresh internal id and waits for its response.
    private func send(_ message: JSONValue) async -> JSONValue {
        let internalID = "pl-\(nextID)"
        nextID += 1
        var outgoing = message
        outgoing["id"] = .string(internalID)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard let process else {
                    continuation.resume(returning: .rpcError(id: nil, code: -32603, message: "\(name) is not running"))
                    return
                }
                pending[internalID] = continuation
                do {
                    try process.send(outgoing)
                } catch {
                    pending[internalID] = nil
                    continuation.resume(returning: .rpcError(id: nil, code: -32603, message: "Write to \(name) failed"))
                }
            }
        } onCancel: {
            Task { await self.abandon(internalID) }
        }
    }

    /// The caller went away: answer its waiter and tell the child to stop.
    private func abandon(_ internalID: String) {
        guard let continuation = pending.removeValue(forKey: internalID) else { return }
        continuation.resume(returning: .rpcError(id: nil, code: -32800, message: "Request cancelled"))
        try? process?.send(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/cancelled"),
            "params": .object(["requestId": .string(internalID), "reason": .string("Client disconnected")]),
        ]))
    }

    // MARK: Child process

    private func ensureRunning() async throws {
        if let process, process.isRunning { return }
        if let starting { return try await starting.value }
        let task = Task { try await self.spawn() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func spawn() async throws {
        let name = self.name
        let log = self.log
        let child = StdioProcess(command: command, environment: environment) { log("[\(name)] \($0)") }
        try child.start()
        process = child
        log("[\(name)] started: \(command.joined(separator: " "))")
        Task {
            for await message in child.messages { await self.route(message) }
            self.exited(child)
        }
        // Clients that initialized before a restart won't do it again; do it for them.
        if let initializeParams {
            let response = await send(.object([
                "jsonrpc": .string("2.0"), "method": .string("initialize"), "params": initializeParams,
            ]))
            guard response["result"] != nil else { throw BridgeError.reinitializeFailed }
            try child.send(Self.initializedNotification)
        }
    }

    private func route(_ message: JSONValue) async {
        if message.isResponse {
            if let id = message.rpcID?.stringValue, let continuation = pending.removeValue(forKey: id) {
                continuation.resume(returning: message)
            }
        } else if message.isRequest {
            // Sampling, roots, elicitation: not relayed to cloud clients yet.
            try? process?.send(.rpcError(id: message.rpcID, code: -32601, message: "Not supported by Porchlight yet"))
        } else if message.rpcMethod == "notifications/progress",
                  let token = message["params"]?["progressToken"],
                  let deliver = progressRoutes[token] {
            await deliver(message)
        }
    }

    private func exited(_ child: StdioProcess) {
        guard process === child else { return }
        process = nil
        for continuation in pending.values {
            continuation.resume(returning: .rpcError(id: nil, code: -32603, message: "\(name) exited"))
        }
        pending.removeAll()
    }
}

enum BridgeError: LocalizedError {
    case reinitializeFailed

    var errorDescription: String? {
        switch self {
        case .reinitializeFailed: "Server restarted but rejected the cached initialize request"
        }
    }
}
