import Foundation

/// A local MCP server that's already running and listening for Streamable HTTP, such as
/// the one Obsidian's Local REST API plugin serves.
///
/// - Sends the configured headers (typically `Authorization`) with every request.
/// - Keeps the server's `Mcp-Session-Id`, and re-initializes once if the server forgets
///   it (a restarted server answers 404).
/// - Reads responses as JSON or SSE, forwarding progress notifications.
/// - Trusts self-signed certificates only on loopback addresses.
public actor HTTPUpstream: Upstream {
    public nonisolated let name: String
    private let url: URL
    private let headers: [String: String]
    private let log: LogSink
    private let onStatus: @Sendable (UpstreamStatus) -> Void
    private let session: URLSession

    private var nextID = 0
    private var sessionID: String?
    private var initializeResult: JSONValue?
    public var handshake: JSONValue? { initializeResult }
    private var negotiatedVersion: String?
    private var connecting: Task<Void, Error>?

    public private(set) var status: UpstreamStatus = .idle {
        didSet { if status != oldValue { onStatus(status) } }
    }

    public init(
        name: String,
        url: URL,
        headers: [String: String] = [:],
        log: @escaping LogSink = stderrLog,
        onStatus: @escaping @Sendable (UpstreamStatus) -> Void = { _ in }
    ) {
        self.name = name
        self.url = url
        self.headers = headers
        self.log = log
        self.onStatus = onStatus
        let configuration = URLSessionConfiguration.ephemeral
        // Tools can take a long time; the request finishes when the server answers.
        configuration.timeoutIntervalForRequest = 24 * 60 * 60
        session = URLSession(configuration: configuration, delegate: LoopbackTrust(), delegateQueue: nil)
    }

    public func initialize() async -> JSONValue {
        do {
            try await ensureConnected()
        } catch {
            return .rpcError(id: nil, code: -32603, message: "Could not reach \(name): \(error.localizedDescription)")
        }
        return .object(["jsonrpc": .string("2.0"), "id": .null, "result": initializeResult ?? .object([:])])
    }

    public func request(_ message: JSONValue, onProgress: ProgressSink?) async -> JSONValue {
        var retried = false
        while true {
            do {
                try await ensureConnected()
                var response = try await exchange(message, onProgress: onProgress)
                status = .running // it may have been unreachable before
                response["id"] = .null
                return response
            } catch HTTPUpstreamError.sessionExpired where !retried {
                log("session expired; reconnecting")
                retried = true
                initializeResult = nil
                sessionID = nil
            } catch is CancellationError {
                return .rpcError(id: nil, code: -32800, message: "Request cancelled")
            } catch {
                status = .failed(error.localizedDescription)
                return .rpcError(id: nil, code: -32603, message: "\(name): \(error.localizedDescription)")
            }
        }
    }

    public func notify(_ message: JSONValue) async {
        do {
            try await ensureConnected()
            _ = try await post(message, onProgress: nil)
        } catch {
            log("dropped notification: \(error.localizedDescription)")
        }
    }

    public func stop() async {
        if let sessionID {
            // Tell the server the session is over; it's fine if it doesn't support that.
            var request = baseRequest(method: "DELETE")
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            _ = try? await session.data(for: request)
        }
        sessionID = nil
        initializeResult = nil
        status = .idle
    }

    // MARK: Connection

    private func ensureConnected() async throws {
        if initializeResult != nil { return }
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
        let response = try await exchange(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .string(StdioUpstream.protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("porchlight"), "version": .string(Porchlight.version)]),
            ]),
        ]), onProgress: nil)
        guard let result = response["result"] else {
            throw HTTPUpstreamError.initializeFailed(response["error"]?["message"]?.stringValue ?? "no result")
        }
        negotiatedVersion = result["protocolVersion"]?.stringValue
        initializeResult = result
        _ = try await post(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]), onProgress: nil)
        status = .running
        log("connected to \(loggableURL(url.absoluteString))")
    }

    // MARK: Transport

    /// Sends a request under an internal id and returns the matching response.
    private func exchange(_ message: JSONValue, onProgress: ProgressSink?) async throws -> JSONValue {
        let internalID = "pl-\(nextID)"
        nextID += 1
        var outgoing = message
        outgoing["id"] = .string(internalID)
        guard let response = try await post(outgoing, onProgress: onProgress, awaiting: .string(internalID)) else {
            throw HTTPUpstreamError.noResponse
        }
        return response
    }

    /// POSTs one message. For a request, returns the response with id `awaiting`, read from
    /// a JSON body or an SSE stream; for a notification, nil.
    @discardableResult
    private func post(_ message: JSONValue, onProgress: ProgressSink?, awaiting id: JSONValue? = nil) async throws -> JSONValue? {
        var request = baseRequest(method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = message.serialized()

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPUpstreamError.noResponse }
        if let assigned = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = assigned }
        if http.statusCode == 404, sessionID != nil, message.rpcMethod != "initialize" {
            throw HTTPUpstreamError.sessionExpired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPUpstreamError.status(http.statusCode, try await Self.prefix(of: bytes))
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

    private func baseRequest(method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private static func prefix(of bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 300 { break }
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum HTTPUpstreamError: LocalizedError {
    case initializeFailed(String)
    case noResponse
    case sessionExpired
    case status(Int, String)

    var errorDescription: String? {
        switch self {
        case .initializeFailed(let message): "initialize failed: \(message)"
        case .noResponse: "The server closed the connection without answering"
        case .sessionExpired: "The server no longer knows this session"
        case .status(401, _), .status(403, _): "The server refused the request (check the Authorization header)"
        case .status(let code, let body): body.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(body)"
        }
    }
}

/// Accepts self-signed certificates for loopback hosts only. Local servers like Obsidian's
/// serve HTTPS with a certificate they generated; anything off this machine is verified
/// normally. Follows redirects only within the same origin, so the server's headers (often
/// an API key) never go anywhere else.
final class LoopbackTrust: NSObject, URLSessionTaskDelegate, Sendable {
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              Self.loopbackHosts.contains(space.host),
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
