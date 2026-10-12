import Foundation

/// Keeps an outbound WebSocket to the relay open and serves tunneled requests with `handler`.
public actor RelayClient {
    public enum Status: Sendable, Equatable {
        case connecting
        case connected
        case disconnected(reason: String)
    }

    static let maxChunk = 192 * 1024
    static let maxMessageSize = 32 * 1024 * 1024
    static let pingInterval: Duration = .seconds(30)
    static let pongTimeout: Duration = .seconds(45)
    // Reconnect waits, in seconds: doubling from the first to the longest, with jitter. A
    // connection that stayed up longer than `healthyConnection` starts over at the first.
    static let firstBackoff = 1.0
    static let longestBackoff = 30.0
    static let healthyConnection: Duration = .seconds(60)

    private let url: URL
    private let secret: String
    private let handler: any HTTPHandler
    private let appVersion: String
    private let onStatus: @Sendable (Status) -> Void
    private let onEvent: @Sendable (RelayEvent) -> Void
    private let queueKey: QueueKey?
    private let ledger: QueueLedger
    private let session = URLSession(configuration: .default)

    private var inflight: [String: Task<Void, Never>] = [:]
    /// Queued requests being run. Unlike `inflight`, they outlive the connection: nobody is
    /// waiting on them, and an approval prompt may still be open.
    private var queuedRunning: Set<String> = []
    private var socket: URLSessionWebSocketTask?
    private var backoff = firstBackoff
    private var backoffWait: Task<Void, Never>?
    private var skipNextWait = false
    private var lastPong = ContinuousClock.now
    private let debug = ProcessInfo.processInfo.environment["PORCHLIGHT_DEBUG"] != nil

    private func trace(_ message: @autoclosure () -> String) {
        if debug { stderrLog("[relay \(Date().formatted(.iso8601.time(includingFractionalSeconds: true)))] \(message())") }
    }

    public init(
        url: URL,
        secret: String,
        handler: any HTTPHandler,
        appVersion: String = "dev",
        queueKey: QueueKey? = nil,
        ledger: QueueLedger = QueueLedger(),
        onStatus: @escaping @Sendable (Status) -> Void = { _ in },
        onEvent: @escaping @Sendable (RelayEvent) -> Void = { _ in }
    ) {
        self.url = url
        self.secret = secret
        self.handler = handler
        self.appVersion = appVersion
        self.queueKey = queueKey
        self.ledger = ledger
        self.onStatus = onStatus
        self.onEvent = onEvent
    }

    // MARK: Control messages

    // Each returns false if it couldn't be sent (not connected, or the connection dropped).

    /// Answers a pairing request from an app's consent page.
    @discardableResult
    public func decidePairing(_ id: String, allow: Bool) async -> Bool {
        await send(HostFrame.pairDecision(id: id, allow: allow))
    }

    /// Asks the relay for the current clients; they arrive as `.clientsChanged`.
    @discardableResult
    public func refreshClients() async -> Bool {
        await send(HostFrame.listClients)
    }

    /// Revokes a connection; the updated list arrives as `.clientsChanged`.
    @discardableResult
    public func revokeClient(_ grantID: String) async -> Bool {
        await send(HostFrame.revokeClient(grantID: grantID))
    }

    /// Tells the relay what an app sees while the Mac is offline (see `Router.offlineCatalog`),
    /// or with nil, to forget it.
    @discardableResult
    public func sendOfflineCatalog(clientID: String, catalog: JSONValue?) async -> Bool {
        await send(HostFrame.offlineCatalog(clientID: clientID, catalog: catalog))
    }

    private func send(_ frame: String) async -> Bool {
        guard let socket else { return false }
        do {
            try await socket.send(.string(frame))
            return true
        } catch {
            trace("send failed: \(error)")
            return false
        }
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

    /// Drops the current connection (if any) and connects again right away, without
    /// waiting out a backoff. For when the network changes or the Mac wakes up: the old
    /// socket is probably dead, and waiting for the keepalive to notice takes up to a minute.
    public func reconnectNow() {
        backoff = Self.firstBackoff
        skipNextWait = socket != nil
        socket?.cancel(with: .goingAway, reason: nil)
        backoffWait?.cancel()
    }

    private func loop() async {
        while !Task.isCancelled {
            onStatus(.connecting)
            let attemptStarted = ContinuousClock.now
            do {
                try await connectAndServe()
            } catch {
                trace("connection ended: \(error)")
                onStatus(.disconnected(reason: error.localizedDescription))
            }
            for task in inflight.values { task.cancel() }
            inflight.removeAll()
            if ContinuousClock.now - attemptStarted > Self.healthyConnection { backoff = Self.firstBackoff }
            if skipNextWait {
                skipNextWait = false
                continue
            }
            let delay = backoff * Double.random(in: 0.8...1.2)
            backoff = min(backoff * 2, Self.longestBackoff)
            let wait = Task { _ = try? await Task.sleep(for: .seconds(delay)) }
            backoffWait = wait
            await wait.value
            backoffWait = nil
        }
    }

    private func connectAndServe() async throws {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue(String(RelayProtocol.version), forHTTPHeaderField: "Porchlight-Protocol")
        let ws = session.webSocketTask(with: request)
        ws.maximumMessageSize = Self.maxMessageSize
        ws.resume()
        socket = ws
        defer {
            ws.cancel(with: .goingAway, reason: nil)
            socket = nil
        }
        if Task.isCancelled { return }

        do {
            try await ws.send(.string(HostFrame.hello(appVersion: appVersion, queueKey: queueKey?.publicKey)))
        } catch {
            throw RelayError.handshake(status: (ws.response as? HTTPURLResponse)?.statusCode, underlying: error)
        }
        onStatus(.connected)
        lastPong = .now
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
            if ContinuousClock.now - lastPong > Self.pongTimeout {
                trace("no pong for \(ContinuousClock.now - lastPong); reconnecting")
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
            lastPong = .now
        case .req(let request):
            let responder = Self.responder(for: request.id, on: ws)
            let handler = self.handler
            inflight[request.id] = Task {
                await handler.handle(request, responder)
                self.finished(request.id)
            }
        case .cancel(let id):
            inflight.removeValue(forKey: id)?.cancel()
        case .queued(let item):
            if ledger.contains(item.id) {
                // Finished before, but the relay didn't hear about it.
                Task { try? await ws.send(.string(HostFrame.queuedDone(id: item.id))) }
            } else if queuedRunning.insert(item.id).inserted {
                Task { await self.runQueued(item) }
            }
        case .event(let event):
            onEvent(event)
        case .unknown:
            break
        }
    }

    private func finished(_ id: String) {
        inflight.removeValue(forKey: id)
    }

    /// Runs a saved request like a live one (same access rules and permissions, with the
    /// time it was made), then tells the relay it's done, on whichever connection is current.
    private func runQueued(_ item: QueuedRequest) async {
        var outcome: QueuedOutcome = .unreadable
        if let queueKey, let body = try? queueKey.open(item.sealed, associated: item.id) {
            let collected = CollectedResponse()
            let encode = { (value: String) in value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
            let request = HTTPRequest(
                id: "queued-\(item.id)", method: "POST", path: item.path,
                headers: [
                    ("content-type", "application/json"),
                    ("accept", "application/json"),
                    (RelayProtocol.clientIDHeader, encode(item.clientID)),
                    (RelayProtocol.clientNameHeader, encode(item.clientName)),
                    (RelayProtocol.queuedAtHeader, item.queuedAt.formatted(.iso8601)),
                ],
                body: body
            )
            await handler.handle(request, collected.responder)
            outcome = collected.succeeded ? .ran : .failed
        }
        ledger.add(item.id)
        queuedRunning.remove(item.id)
        onEvent(.queuedFinished(item, outcome))
        await send(HostFrame.queuedDone(id: item.id))
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

/// Collects a response nobody is waiting for, just to tell whether the call worked.
private final class CollectedResponse: Sendable {
    private let state = Locked((status: 0, body: Data()))

    var responder: HTTPResponder {
        HTTPResponder(
            start: { status, _ in self.state.withLock { $0.status = status } },
            chunk: { data in self.state.withLock { $0.body.append(data) } },
            end: {}
        )
    }

    /// A 2xx answer that isn't a JSON-RPC error or a tool result marked as one.
    var succeeded: Bool {
        let (status, body) = state.value
        guard (200..<300).contains(status), let response = try? JSONValue.parse(body) else { return false }
        return response.failure == nil
    }
}
