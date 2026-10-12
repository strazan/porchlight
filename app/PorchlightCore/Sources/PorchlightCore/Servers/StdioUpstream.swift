import Foundation

/// A local MCP server that runs as a child process, speaking JSON-RPC over stdio.
///
/// - Porchlight performs the `initialize` handshake itself when it starts the child. A
///   restarted child is re-initialized transparently.
/// - Requests go out under internal ids (`pl-N`), so clients can't collide; the caller
///   puts the client's id back on the response.
/// - The child starts lazily, on first use.
actor StdioUpstream: Upstream {
    nonisolated let name: String
    private let command: [String]
    private let environment: [String: String]?
    private let log: LogSink
    private let onStatus: UpstreamStatusSink

    static let initializeTimeout: Duration = .seconds(60)

    private var process: StdioProcess?
    private var starting: Task<Void, Error>?
    private var stopping = false
    private var nextID = 0
    private var pending: [String: CheckedContinuation<JSONValue, Never>] = [:]
    private var progressRoutes: [JSONValue: ProgressSink] = [:]
    private(set) var handshake: JSONValue?

    private(set) var status: UpstreamStatus = .idle {
        didSet { if status != oldValue { onStatus(status) } }
    }

    init(
        name: String,
        command: [String],
        environment: [String: String]? = nil,
        log: @escaping LogSink = stderrLog,
        onStatus: @escaping UpstreamStatusSink = { _ in }
    ) {
        self.name = name
        self.command = command
        self.environment = environment
        self.log = log
        self.onStatus = onStatus
    }

    func initialize() async -> JSONValue {
        do {
            try await ensureRunning()
        } catch {
            return .rpcError(id: nil, code: .internalError, message: "Could not start \(name): \(error.localizedDescription)")
        }
        return .rpcResult(handshake ?? .object([:]))
    }

    func request(_ message: JSONValue, onProgress: ProgressSink?) async -> JSONValue {
        do {
            try await ensureRunning()
        } catch {
            return .rpcError(id: nil, code: .internalError, message: "Could not start \(name): \(error.localizedDescription)")
        }
        let token = message["params"]?["_meta"]?["progressToken"]
        if let token, let onProgress { progressRoutes[token] = onProgress }
        var response = await send(message)
        if let token { progressRoutes[token] = nil }
        response["id"] = .null
        return response
    }

    func notify(_ message: JSONValue) async {
        do {
            try await ensureRunning()
            try process?.send(message)
        } catch {
            log("dropped notification: \(error.localizedDescription)")
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
        status = .idle
    }

    // MARK: Child process

    private func ensureRunning() async throws {
        if let process, process.isRunning, handshake != nil { return }
        if let starting { return try await starting.value }
        let task = Task { try await self.spawn() }
        starting = task
        defer { starting = nil }
        do {
            try await task.value
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    private func spawn() async throws {
        stopping = false
        status = .starting
        handshake = nil
        let child = StdioProcess(command: command, environment: environment, log: log)
        try child.start()
        process = child
        log("started: \(loggableCommandLine(command))")
        Task {
            for await message in child.messages { await self.route(message) }
            // Answer waiters as soon as output ends; the exit status can take a moment longer.
            guard self.outputEnded(child) else { return }
            let exitStatus = await child.exitStatus()
            // Unless it has been restarted meanwhile, say how it ended.
            if self.status == .failed("Exited") { self.status = .failed("Exited with status \(exitStatus)") }
        }

        let response = await send(MCP.initializeRequest, timeout: Self.initializeTimeout)
        guard let result = response["result"] else {
            child.terminate()
            throw UpstreamError.initializeFailed(response.failure ?? "no response")
        }
        handshake = result
        try child.send(MCP.initializedNotification)
        status = .running
    }

    /// Sends a request to the child under a fresh internal id and waits for its response.
    private func send(_ message: JSONValue, timeout: Duration? = nil) async -> JSONValue {
        let internalID = "pl-\(nextID)"
        nextID += 1
        var outgoing = message
        outgoing["id"] = .string(internalID)
        let timer = timeout.map { timeout in
            Task {
                try await Task.sleep(for: timeout)
                self.resolve(internalID, with: .rpcError(id: nil, code: .internalError, message: "\(self.name) did not respond"))
            }
        }
        defer { timer?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard let process else {
                    continuation.resume(returning: .rpcError(id: nil, code: .internalError, message: "\(name) is not running"))
                    return
                }
                pending[internalID] = continuation
                do {
                    try process.send(outgoing)
                } catch {
                    pending[internalID] = nil
                    continuation.resume(returning: .rpcError(id: nil, code: .internalError, message: "Write to \(name) failed"))
                }
            }
        } onCancel: {
            Task { await self.abandon(internalID) }
        }
    }

    private func resolve(_ internalID: String, with response: JSONValue) {
        pending.removeValue(forKey: internalID)?.resume(returning: response)
    }

    /// The caller went away: answer its waiter and tell the child to stop.
    private func abandon(_ internalID: String) {
        guard pending[internalID] != nil else { return }
        resolve(internalID, with: .rpcError(id: nil, code: .requestCancelled, message: "Request cancelled"))
        try? process?.send(.rpcRequest(
            "notifications/cancelled", params: ["requestId": .string(internalID), "reason": .string("The app disconnected")]
        ))
    }

    private func route(_ message: JSONValue) async {
        if message.isResponse {
            if let id = message.rpcID?.stringValue { resolve(id, with: message) }
        } else if message.isRequest {
            // Sampling, roots, elicitation: not relayed to cloud agents yet.
            try? process?.send(.rpcError(id: message.rpcID, code: .methodNotFound, message: "Not supported by Porchlight yet"))
        } else if message.rpcMethod == "notifications/progress",
                  let token = message["params"]?["progressToken"],
                  let deliver = progressRoutes[token] {
            await deliver(message)
        }
    }

    /// The child stopped writing: it's gone (or as good as). Returns whether it was the current one.
    private func outputEnded(_ child: StdioProcess) -> Bool {
        guard process === child else { return false }
        process = nil
        handshake = nil
        for continuation in pending.values {
            continuation.resume(returning: .rpcError(id: nil, code: .internalError, message: "\(name) exited"))
        }
        pending.removeAll()
        child.terminate()
        if !stopping { status = .failed("Exited") }
        return true
    }
}
