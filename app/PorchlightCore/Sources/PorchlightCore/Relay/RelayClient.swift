import Foundation

/// Keeps an outbound WebSocket to the relay open and serves tunneled requests with `handler`.
public actor RelayClient {
    public enum Status: Sendable, Equatable {
        case connecting
        case connected
        case disconnected(reason: String)
    }

    static let maxChunk = 192 * 1024
    static let pingInterval: Duration = .seconds(30)
    static let pongTimeout: TimeInterval = 45

    private let url: URL
    private let secret: String
    private let handler: any HTTPHandler
    private let appVersion: String
    private let onStatus: @Sendable (Status) -> Void
    private let onEvent: @Sendable (RelayEvent) -> Void
    private let session = URLSession(configuration: .default)

    private var inflight: [String: Task<Void, Never>] = [:]
    private var socket: URLSessionWebSocketTask?
    private var lastPong = Date()
    private let debug = ProcessInfo.processInfo.environment["PORCHLIGHT_DEBUG"] != nil

    private func trace(_ message: @autoclosure () -> String) {
        if debug { stderrLog("[relay \(Date().formatted(.iso8601.time(includingFractionalSeconds: true)))] \(message())") }
    }

    public init(
        url: URL,
        secret: String,
        handler: any HTTPHandler,
        appVersion: String = "dev",
        onStatus: @escaping @Sendable (Status) -> Void = { _ in },
        onEvent: @escaping @Sendable (RelayEvent) -> Void = { _ in }
    ) {
        self.url = url
        self.secret = secret
        self.handler = handler
        self.appVersion = appVersion
        self.onStatus = onStatus
        self.onEvent = onEvent
    }

    // MARK: Control messages

    /// Answers a pairing request from an app's consent page.
    public func decidePairing(_ id: String, allow: Bool) async {
        try? await socket?.send(.string(HostFrame.pairDecision(id: id, allow: allow)))
    }

    /// Asks the relay for the current clients; they arrive as `.clientsChanged`.
    public func refreshClients() async {
        try? await socket?.send(.string(HostFrame.listClients))
    }

    /// Revokes a client's access; the updated list arrives as `.clientsChanged`.
    public func revokeClient(_ grantID: String) async {
        try? await socket?.send(.string(HostFrame.revokeClient(grantID: grantID)))
    }

    /// Connects and reconnects (with jittered backoff) until the calling task is cancelled.
    public func run() async {
        await withTaskCancellationHandler {
            await loop()
        } onCancel: {
            // `receive()` doesn't observe task cancellation; closing the socket ends it.
            Task { await self.closeSocket() }
        }
    }

    private func closeSocket() {
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    private func loop() async {
        var backoff = 1.0
        while !Task.isCancelled {
            onStatus(.connecting)
            let attemptStarted = Date()
            do {
                try await connectAndServe()
            } catch {
                trace("connection ended: \(error)")
                onStatus(.disconnected(reason: error.localizedDescription))
            }
            for task in inflight.values { task.cancel() }
            inflight.removeAll()
            // A connection that stayed up for a while was healthy; start over with short waits.
            if Date().timeIntervalSince(attemptStarted) > 60 { backoff = 1 }
            try? await Task.sleep(for: .seconds(backoff * Double.random(in: 0.8...1.2)))
            backoff = min(backoff * 2, 30)
        }
    }

    private func connectAndServe() async throws {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue(String(RelayProtocol.version), forHTTPHeaderField: "Porchlight-Protocol")
        let ws = session.webSocketTask(with: request)
        ws.maximumMessageSize = 32 * 1024 * 1024
        ws.resume()
        socket = ws
        defer {
            ws.cancel(with: .goingAway, reason: nil)
            socket = nil
        }
        if Task.isCancelled { return }

        do {
            try await ws.send(.string(HostFrame.hello(appVersion: appVersion)))
        } catch {
            throw RelayError.handshake(status: (ws.response as? HTTPURLResponse)?.statusCode, underlying: error)
        }
        onStatus(.connected)
        lastPong = Date()
        try? await ws.send(.string(HostFrame.listClients))

        let keepalive = Task { await self.keepalive(ws) }
        defer { keepalive.cancel() }

        while true {
            if case .string(let text) = try await ws.receive() {
                receive(text, on: ws)
            }
        }
    }

    private func keepalive(_ ws: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pingInterval)
            if Task.isCancelled { return }
            if Date().timeIntervalSince(lastPong) > Self.pongTimeout {
                trace("no pong for \(Int(Date().timeIntervalSince(lastPong)))s; reconnecting")
                // Unblocks the receive loop with an error, which triggers a reconnect.
                ws.cancel(with: .goingAway, reason: nil)
                return
            }
            trace("ping")
            try? await ws.send(.string(RelayProtocol.ping))
        }
    }

    private func receive(_ text: String, on ws: URLSessionWebSocketTask) {
        switch RelayFrame.decode(text) {
        case .pong:
            trace("pong")
            lastPong = Date()
        case .req(let request):
            let responder = Self.responder(for: request.id, on: ws)
            let handler = self.handler
            inflight[request.id] = Task {
                await handler.handle(request, responder)
                self.finished(request.id)
            }
        case .cancel(let id):
            inflight.removeValue(forKey: id)?.cancel()
        case .event(let event):
            onEvent(event)
        case .unknown:
            break
        }
    }

    private func finished(_ id: String) {
        inflight.removeValue(forKey: id)
    }

    /// Sends go straight to the socket the request arrived on. If that socket has since
    /// been replaced, the sends fail quietly: the relay already failed the request.
    private static func responder(for id: String, on ws: URLSessionWebSocketTask) -> HTTPResponder {
        HTTPResponder(
            start: { status, headers in
                try? await ws.send(.string(HostFrame.resStart(id: id, status: status, headers: headers)))
            },
            chunk: { data in
                var offset = 0
                while offset < data.count {
                    let end = min(offset + maxChunk, data.count)
                    try? await ws.send(.string(HostFrame.resChunk(id: id, data: data.subdata(in: offset..<end))))
                    offset = end
                }
            },
            end: {
                try? await ws.send(.string(HostFrame.resEnd(id: id)))
            }
        )
    }
}

public enum RelayError: LocalizedError {
    case handshake(status: Int?, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .handshake(401?, _): "Relay rejected the secret (401)"
        case .handshake(426?, _): "Relay speaks a different protocol version (426)"
        case .handshake(let status?, _): "Relay handshake failed (HTTP \(status))"
        case .handshake(nil, let underlying): "Could not reach relay: \(underlying.localizedDescription)"
        }
    }
}
