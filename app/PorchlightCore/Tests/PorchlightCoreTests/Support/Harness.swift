import Foundation
@testable import PorchlightCore

/// A router serving test servers, recording what it asks and does.
struct Harness {
    let router: Router
    /// Approval requests, in order.
    let asked = Locked<[ToolApprovalRequest]>([])
    let activity = Locked<[ActivityEvent]>([])
    /// Server → every status it reported, in order.
    let statuses = Locked<[String: [UpstreamStatus]]>([:])

    /// `answer`: how every approval request is answered.
    init(_ servers: [ServerConfig], answer: ToolApproval = .deny, access: [String: Set<String>] = [:]) async {
        let asked = self.asked
        let activity = self.activity
        let statuses = self.statuses
        router = Router(
            environment: ProcessInfo.processInfo.environment,
            log: { _, _ in },
            onStatus: { server, status in statuses.withLock { $0[server, default: []].append(status) } },
            approve: { request in
                asked.withLock { $0.append(request) }
                return answer
            },
            onActivity: { event in activity.withLock { $0.append(event) } }
        )
        await router.apply(servers)
        await router.setClientAccess(access)
    }

    /// A request as the relay forwards it: from `client` (none: not through the relay's
    /// OAuth), and with `queuedAt` if the relay saved it while the Mac was offline.
    @discardableResult
    func post(
        _ body: String,
        path: String = "/mcp",
        accept: String = "application/json",
        from client: ClientIdentity? = nil,
        queuedAt: Date? = nil
    ) async -> RecordedResponse {
        var headers: HeaderList = [("accept", accept), ("content-type", "application/json")]
        let encode = { (value: String) in value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
        if let client {
            headers.append((RelayProtocol.clientIDHeader, encode(client.id)))
            headers.append((RelayProtocol.clientNameHeader, encode(client.name)))
        }
        if let queuedAt { headers.append((RelayProtocol.queuedAtHeader, queuedAt.formatted(.iso8601))) }
        let recorded = RecordedResponse()
        await router.handle(HTTPRequest(id: UUID().uuidString, method: "POST", path: path, headers: headers, body: Data(body.utf8)), recorded.responder)
        return recorded
    }
}

extension ClientIdentity {
    static let claude = ClientIdentity(id: "claude", name: "Claude")
    static let chatgpt = ClientIdentity(id: "chatgpt", name: "ChatGPT")
}

/// Runs `body` with a harness, then stops its servers (and waits for them to stop).
func withRouter<T>(
    _ servers: [ServerConfig],
    answer: ToolApproval = .deny,
    access: [String: Set<String>] = [:],
    _ body: (Harness) async throws -> T
) async rethrows -> T {
    let harness = await Harness(servers, answer: answer, access: access)
    do {
        let result = try await body(harness)
        await harness.router.stopAll()
        return result
    } catch {
        await harness.router.stopAll()
        throw error
    }
}

/// Collects what a handler writes to its responder.
actor RecordedResponse {
    var status: Int?
    var headers: HeaderList = []
    var body = Data()
    var ended = false

    var text: String { String(decoding: body, as: UTF8.self) }
    var json: JSONValue? { try? JSONValue.parse(body) }

    nonisolated var responder: HTTPResponder {
        HTTPResponder(
            start: { status, headers in await self.started(status, headers) },
            chunk: { data in await self.append(data) },
            end: { await self.finish() }
        )
    }

    private func started(_ status: Int, _ headers: HeaderList) {
        self.status = status
        self.headers = headers
    }

    private func append(_ data: Data) { body.append(data) }
    private func finish() { ended = true }

    func header(_ name: String) -> String? {
        headers.first { $0.name.lowercased() == name }?.value
    }
}

// MARK: Test servers

private let fakeScript = Bundle.module.path(forResource: "fake_server", ofType: "py", inDirectory: "Fixtures")!

/// `fake_server.py` as a stdio server. Tools run without approval unless a test sets a
/// stricter policy.
func fakeConfig(_ name: String, enabled: Bool = true, policy: ToolPolicy = ToolPolicy(defaultPermission: .allowAll)) -> ServerConfig {
    var config = ServerConfig(name: name, command: "python3", args: ["-u", fakeScript], env: ["FAKE_NAME": name], enabled: enabled)
    config.toolPolicy = policy
    return config
}

/// A fake server that also lists an additive tool (`add`) and a destructive one (`remove`).
func queueConfig(_ name: String, policy: ToolPolicy = ToolPolicy(defaultPermission: .allowAll)) -> ServerConfig {
    var config = fakeConfig(name, policy: policy)
    config.env["FAKE_MORE_TOOLS"] = "1"
    return config
}

/// Runs `fake_http_server.py` and yields its /mcp URL.
final class FakeHTTPServer: @unchecked Sendable {
    let url: URL
    private let process = Process()

    init() throws {
        let script = Bundle.module.path(forResource: "fake_http_server", ofType: "py", inDirectory: "Fixtures")!
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", script]
        process.standardOutput = stdout
        try process.run()
        // The first line is the port it's listening on.
        var line = Data()
        while true {
            let byte = stdout.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty || byte == Data("\n".utf8) { break }
            line.append(byte)
        }
        url = URL(string: "http://127.0.0.1:\(String(decoding: line, as: UTF8.self))/mcp/")!
    }

    deinit { process.terminate() }
}

func httpConfig(_ name: String, url: URL, key: String = "test-key") -> ServerConfig {
    var config = ServerConfig(name: name, url: url.absoluteString, headers: ["Authorization": "Bearer \(key)"])
    config.toolPolicy = ToolPolicy(defaultPermission: .allowAll)
    return config
}

/// The repository's root folder, for files outside the package (like protocol/vectors).
let repositoryRoot = URL(filePath: #filePath) // app/PorchlightCore/Tests/PorchlightCoreTests/Support/Harness.swift
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

// MARK: Messages

func rpc(_ id: Int, _ method: String, _ params: String = "{}") -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
}

func callTool(id: Int, _ name: String, _ args: String = "{}") -> String {
    rpc(id, "tools/call", #"{"name":"\#(name)","arguments":\#(args)}"#)
}

let initialize = rpc(0, "initialize", #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}"#)

/// The `text` of the first content block in a tools/call result, parsed as JSON.
func toolText(_ response: JSONValue?) -> JSONValue? {
    guard case .array(let content)? = response?["result"]?["content"],
          let text = content.first?["text"]?.stringValue
    else { return nil }
    return try? JSONValue.parse(Data(text.utf8))
}

func names(_ response: JSONValue?, _ key: String) -> [String] {
    guard case .array(let items)? = response?["result"]?[key] else { return [] }
    return items.compactMap { $0["name"]?.stringValue }
}

/// Parses the `data:` lines of an SSE body.
func sseMessages(_ body: String) -> [JSONValue] {
    body.split(separator: "\n")
        .filter { $0.hasPrefix("data: ") }
        .compactMap { try? JSONValue.parse(Data($0.dropFirst(6).utf8)) }
}
