import Foundation

/// A local MCP server that's already running and listening for Streamable HTTP, such as
/// the one Obsidian's Local REST API plugin serves.
///
/// - Sends the configured headers (typically `Authorization`) with every request.
/// - Keeps the server's `Mcp-Session-Id`, and re-initializes once if the server forgets
///   it (a restarted server answers 404).
/// - Reads responses as JSON or SSE, forwarding progress notifications.
/// - Trusts self-signed certificates only on loopback addresses.
actor HTTPUpstream: Upstream {
    nonisolated let name: String
    /// Nil for a config whose URL doesn't parse: every request then fails, saying so.
    private let url: URL?
    private let headers: [String: String]
    private let log: LogSink
    private let onStatus: UpstreamStatusSink
    private let session: URLSession

    /// Tools can take a long time; a request finishes when the server answers.
    static let requestTimeout: TimeInterval = 24 * 3600
    static let initializeTimeout: TimeInterval = 60
    /// How much of an error response to quote.
    static let errorBodyLimit = 300

    private var nextID = 0
    private var sessionID: String?
    private(set) var handshake: JSONValue?
    private var negotiatedVersion: String?
    private var connecting: Task<Void, Error>?

    private(set) var status: UpstreamStatus = .idle {
        didSet { if status != oldValue { onStatus(status) } }
    }

    init(
        name: String,
        url: URL?,
        headers: [String: String] = [:],
        log: @escaping LogSink = stderrLog,
        onStatus: @escaping UpstreamStatusSink = { _ in }
    ) {
        self.name = name
        self.url = url
        self.headers = headers
        self.log = log
        self.onStatus = onStatus
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        session = URLSession(configuration: configuration, delegate: HTTPUpstreamDelegate(), delegateQueue: nil)
    }

    func initialize() async -> JSONValue {
        do {
            try await ensureConnected()
        } catch {
            return .rpcError(id: nil, code: .internalError, message: "Could not reach \(name): \(error.localizedDescription)")
        }
        return .rpcResult(handshake ?? .object([:]))
    }

    func request(_ message: JSONValue, onProgress: ProgressSink?) async -> JSONValue {
        var retried = false
        while true {
            do {
                try await ensureConnected()
                var response = try await exchange(message, onProgress: onProgress)
                status = .running // it may have been unreachable before
                response["id"] = .null
                return response
            } catch UpstreamError.sessionExpired where !retried {
                log("session expired; reconnecting")
                retried = true
                handshake = nil
                sessionID = nil
            } catch is CancellationError {
                return .rpcError(id: nil, code: .requestCancelled, message: "Request cancelled")
            } catch {
                status = .failed(error.localizedDescription)
                return .rpcError(id: nil, code: .internalError, message: "\(name): \(error.localizedDescription)")
            }
        }
    }

    func notify(_ message: JSONValue) async {
        do {
            try await ensureConnected()
            _ = try await post(message, onProgress: nil)
        } catch {
            log("dropped notification: \(error.localizedDescription)")
        }
    }

    func stop() async {
        if let sessionID, var request = try? baseRequest(method: "DELETE") {
            // Tell the server the session is over; it's fine if it doesn't support that.
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            _ = try? await session.data(for: request)
        }
        sessionID = nil
        handshake = nil
        status = .idle
    }

    // MARK: Connection

    private func ensureConnected() async throws {
        if handshake != nil { return }
        if let connecting { return try await connecting.value }
        let task = Task { try await self.connect() }
        connecting = task
        defer { connecting = nil }
        do {
            try await task.value
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    private func connect() async throws {
        status = .starting
        sessionID = nil
        negotiatedVersion = nil
        let response = try await exchange(MCP.initializeRequest, onProgress: nil, timeout: Self.initializeTimeout)
        guard let result = response["result"] else {
            throw UpstreamError.initializeFailed(response.failure ?? "no result")
        }
        negotiatedVersion = result["protocolVersion"]?.stringValue
        handshake = result
        try await post(MCP.initializedNotification, onProgress: nil)
        status = .running
        log("connected to \(loggableURL(url?.absoluteString ?? ""))")
    }

    // MARK: Transport

    /// Sends a request under an internal id and returns the matching response.
    private func exchange(_ message: JSONValue, onProgress: ProgressSink?, timeout: TimeInterval? = nil) async throws -> JSONValue {
        let internalID = "pl-\(nextID)"
        nextID += 1
        var outgoing = message
        outgoing["id"] = .string(internalID)
        guard let response = try await post(outgoing, onProgress: onProgress, awaiting: .string(internalID), timeout: timeout) else {
            throw UpstreamError.noResponse
        }
        return response
    }

    /// POSTs one message. For a request, returns the response with id `awaiting`, read from
    /// a JSON body or an SSE stream; for a notification, nil.
    @discardableResult
    private func post(
        _ message: JSONValue, onProgress: ProgressSink?, awaiting id: JSONValue? = nil, timeout: TimeInterval? = nil
    ) async throws -> JSONValue? {
        var request = try baseRequest(method: "POST")
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = message.serialized()

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpstreamError.noResponse }
        if let assigned = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = assigned }
        if http.statusCode == 404, sessionID != nil, message.rpcMethod != "initialize" {
            throw UpstreamError.sessionExpired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpstreamError.status(http.statusCode, try await Self.prefix(of: bytes))
        }
        guard let id else { return nil }

        if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            return try await readEvents(bytes, awaiting: id, onProgress: onProgress)
        }
        var body = Data()
        for try await byte in bytes { body.append(byte) }
        let parsed = try JSONValue.parse(body)
        if case .array(let batch) = parsed { return batch.first { $0.rpcID == id } }
        return parsed
    }

    /// Reads SSE `data:` messages until the response to `id` arrives.
    private func readEvents(_ bytes: URLSession.AsyncBytes, awaiting id: JSONValue, onProgress: ProgressSink?) async throws -> JSONValue? {
        var pending = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            var data = line.dropFirst(5)
            if data.first == " " { data = data.dropFirst() }
            // A message usually fits on one data line; a split one is joined until it parses.
            pending = pending.isEmpty ? String(data) : pending + "\n" + data
            guard let message = try? JSONValue.parse(Data(pending.utf8)) else { continue }
            pending = ""
            if message.isResponse, message.rpcID == id { return message }
            if message.rpcMethod == "notifications/progress", let onProgress { await onProgress(message) }
        }
        return nil
    }

    private func baseRequest(method: String) throws -> URLRequest {
        guard let url else { throw UpstreamError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private static func prefix(of bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= errorBodyLimit { break }
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// How an HTTP upstream's connections are trusted:
/// - Self-signed certificates are accepted for loopback hosts only. Local servers like
///   Obsidian's serve HTTPS with a certificate they generated; anything off this Mac is
///   verified normally.
/// - Redirects are followed only within the same origin, so the server's headers (often an
///   API key) never go anywhere else.
final class HTTPUpstreamDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              Hosts.isLoopback(space.host),
              let trust = space.serverTrust
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        Self.sameOrigin(task.originalRequest?.url, request.url) ? request : nil
    }

    static func sameOrigin(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host()?.lowercased() == b.host()?.lowercased()
            && (a.port ?? defaultPort(a)) == (b.port ?? defaultPort(b))
    }

    private static func defaultPort(_ url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "https": 443
        case "http": 80
        default: nil
        }
    }
}
