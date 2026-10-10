import Foundation
import Testing
@testable import PorchlightCore

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

/// A value shared with `@Sendable` callbacks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func withLock(_ body: (inout Value) -> Void) {
        lock.withLock { body(&stored) }
    }
}

let fakeScript = Bundle.module.path(forResource: "fake_server", ofType: "py", inDirectory: "Fixtures")!

func fakeConfig(_ name: String, enabled: Bool = true) -> ServerConfig {
    ServerConfig(name: name, command: "python3", args: ["-u", fakeScript], env: ["FAKE_NAME": name], enabled: enabled)
}

func makeRouter(_ servers: [ServerConfig]) async -> Router {
    let router = Router(environment: ProcessInfo.processInfo.environment, log: { _, _ in })
    await router.apply(servers)
    return router
}

@discardableResult
func post(
    _ router: Router,
    _ body: String,
    path: String = "/mcp",
    accept: String = "application/json"
) async -> RecordedResponse {
    let recorded = RecordedResponse()
    let request = HTTPRequest(
        id: UUID().uuidString, method: "POST", path: path,
        headers: [("accept", accept), ("content-type", "application/json")],
        body: Data(body.utf8)
    )
    await router.handle(request, recorded.responder)
    return recorded
}

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

@Suite struct PassthroughTests {
    @Test func initializesAndKeepsClientIDs() async {
        let router = await makeRouter([fakeConfig("fake")])
        defer { Task { await router.stopAll() } }

        let initialized = await post(router, initialize, path: "/mcp/fake")
        #expect(await initialized.status == 200)
        #expect(await initialized.json?["id"] == .int(0))
        #expect(await initialized.json?["result"]?["serverInfo"]?["name"] == .string("fake"))

        let list = await post(router, #"{"jsonrpc":"2.0","id":"abc","method":"tools/list"}"#, path: "/mcp/fake")
        #expect(await list.json?["id"] == .string("abc"))
        #expect(await list.header("content-type") == "application/json")
    }

    @Test func clientsReusingAnIDDoNotCollide() async {
        let router = await makeRouter([fakeConfig("fake")])
        defer { Task { await router.stopAll() } }

        async let a = post(router, callTool(id: 1, "echo", #"{"who":"a"}"#), path: "/mcp/fake")
        async let b = post(router, callTool(id: 1, "echo", #"{"who":"b"}"#), path: "/mcp/fake")
        let (ra, rb) = await (a, b)

        let ea = toolText(await ra.json), eb = toolText(await rb.json)
        #expect(await ra.json?["id"] == .int(1))
        #expect(await rb.json?["id"] == .int(1))
        #expect(ea?["args"]?["who"] == .string("a"))
        #expect(eb?["args"]?["who"] == .string("b"))
        // The child saw two distinct internal ids.
        #expect(ea?["id"] != eb?["id"])
    }

    @Test func clientInitializeIsAnsweredFromPorchlightsHandshake() async {
        let router = await makeRouter([fakeConfig("fake")])
        defer { Task { await router.stopAll() } }
        await post(router, initialize, path: "/mcp/fake")
        let again = await post(router, initialize.replacingOccurrences(of: #""id":0"#, with: #""id":9"#), path: "/mcp/fake")
        #expect(await again.json?["id"] == .int(9))

        let stats = await post(router, callTool(id: 2, "stats"), path: "/mcp/fake")
        #expect(toolText(await stats.json)?["initialize_count"] == .int(1))
    }

    @Test func streamsToolCallsWithProgress() async {
        let router = await makeRouter([fakeConfig("fake")])
        defer { Task { await router.stopAll() } }

        let call = rpc(5, "tools/call", #"{"name":"slow","arguments":{"seconds":0.1},"_meta":{"progressToken":"tok"}}"#)
        let response = await post(router, call, path: "/mcp/fake", accept: "application/json, text/event-stream")
        #expect(await response.status == 200)
        #expect(await response.header("content-type") == "text/event-stream")
        #expect(await response.ended)

        let messages = sseMessages(await response.text)
        #expect(messages.count == 2)
        #expect(messages.first?["method"] == .string("notifications/progress"))
        #expect(messages.first?["params"]?["progressToken"] == .string("tok"))
        #expect(messages.last?["id"] == .int(5))
        #expect(messages.last?["result"] != nil)
    }

    @Test func restartsACrashedServerTransparently() async {
        let statuses = Locked<[UpstreamStatus]>([])
        let router = Router(environment: ProcessInfo.processInfo.environment, log: { _, _ in }, onStatus: { _, status in
            statuses.withLock { $0.append(status) }
        })
        await router.apply([fakeConfig("fake")])
        defer { Task { await router.stopAll() } }

        let crashed = await post(router, callTool(id: 3, "crash"), path: "/mcp/fake")
        #expect(await crashed.json?["error"]?["message"] == .string("fake exited"))

        // The client never re-initializes; Porchlight does it for the new process.
        let stats = await post(router, callTool(id: 4, "stats"), path: "/mcp/fake")
        #expect(toolText(await stats.json)?["initialize_count"] == .int(1))
        #expect(await stats.json?["id"] == .int(4))
        #expect(statuses.value.contains(.failed("Exited with status 1")))
        #expect(statuses.value.last == .running)
    }

    @Test func httpEdges() async {
        let router = await makeRouter([fakeConfig("fake")])
        defer { Task { await router.stopAll() } }

        let notification = await post(router, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, path: "/mcp/fake")
        #expect(await notification.status == 202)

        let badJSON = await post(router, "{nope", path: "/mcp/fake")
        #expect(await badJSON.status == 400)
        #expect(await badJSON.json?["error"]?["code"] == .int(-32700))

        let unknown = await post(router, initialize, path: "/mcp/other")
        #expect(await unknown.status == 404)
        let withQuery = await post(router, initialize, path: "/mcp/fake?x=1")
        #expect(await withQuery.status == 200)

        let get = RecordedResponse()
        await router.handle(HTTPRequest(id: "g", method: "GET", path: "/mcp"), get.responder)
        #expect(await get.status == 405)
    }
}

@Suite struct AggregatorTests {
    @Test func initializesAsPorchlight() async {
        let router = await makeRouter([fakeConfig("alpha")])
        defer { Task { await router.stopAll() } }
        let response = await post(router, initialize)
        #expect(await response.json?["result"]?["serverInfo"]?["name"] == .string("porchlight"))
        #expect(await response.json?["result"]?["protocolVersion"] == .string("2025-06-18"))
        #expect(await response.json?["result"]?["capabilities"]?["tools"] != nil)
    }

    @Test func combinesAndRoutesTools() async {
        let router = await makeRouter([fakeConfig("alpha"), fakeConfig("beta")])
        defer { Task { await router.stopAll() } }

        let list = await post(router, rpc(1, "tools/list"))
        #expect(names(await list.json, "tools") == ["alpha__echo", "beta__echo"])
        guard case .array(let tools)? = await list.json?["result"]?["tools"] else {
            Issue.record("no tools")
            return
        }
        #expect(tools.first?["title"] == .string("echo"))

        let call = await post(router, callTool(id: 2, "beta__echo", #"{"x":1}"#))
        #expect(await call.json?["id"] == .int(2))
        #expect(toolText(await call.json)?["server"] == .string("beta"))
        #expect(toolText(await call.json)?["args"]?["x"] == .int(1))
    }

    @Test func routesCallsWithoutAPriorList() async {
        let router = await makeRouter([fakeConfig("alpha"), fakeConfig("beta")])
        defer { Task { await router.stopAll() } }
        let call = await post(router, callTool(id: 3, "alpha__echo"))
        #expect(toolText(await call.json)?["server"] == .string("alpha"))

        let unknown = await post(router, callTool(id: 4, "gamma__echo"))
        #expect(await unknown.json?["error"]?["code"] == .int(-32602))
    }

    @Test func combinesPromptsAndResources() async {
        let router = await makeRouter([fakeConfig("alpha"), fakeConfig("beta")])
        defer { Task { await router.stopAll() } }

        let prompts = await post(router, rpc(1, "prompts/list"))
        #expect(names(await prompts.json, "prompts") == ["alpha__greet", "beta__greet"])
        let prompt = await post(router, rpc(2, "prompts/get", #"{"name":"beta__greet"}"#))
        guard case .array(let messages)? = await prompt.json?["result"]?["messages"] else {
            Issue.record("no messages")
            return
        }
        #expect(messages.first?["content"]?["text"] == .string("hello from beta"))

        let resources = await post(router, rpc(3, "resources/list"))
        #expect(names(await resources.json, "resources") == ["readme", "readme"])
        let read = await post(router, rpc(4, "resources/read", #"{"uri":"fake://beta/readme"}"#))
        guard case .array(let contents)? = await read.json?["result"]?["contents"] else {
            Issue.record("no contents")
            return
        }
        #expect(contents.first?["text"] == .string("beta"))
    }

    @Test func skipsServersThatFailToStart() async {
        let broken = ServerConfig(name: "broken", command: "/nonexistent/server")
        let router = await makeRouter([broken, fakeConfig("alpha")])
        defer { Task { await router.stopAll() } }
        let list = await post(router, rpc(1, "tools/list"))
        #expect(names(await list.json, "tools") == ["alpha__echo"])
    }

    @Test func appliesConfigChangesLive() async {
        let router = await makeRouter([fakeConfig("alpha"), fakeConfig("beta")])
        defer { Task { await router.stopAll() } }
        #expect(await post(router, initialize, path: "/mcp/beta").status == 200)

        await router.apply([fakeConfig("alpha"), fakeConfig("beta", enabled: false)])
        #expect(await post(router, initialize, path: "/mcp/beta").status == 404)
        let list = await post(router, rpc(1, "tools/list"))
        #expect(names(await list.json, "tools") == ["alpha__echo"])
    }

    @Test func aliasesFitClientNameRules() {
        #expect(Aggregator.alias(server: "files", name: "read_file") == "files__read_file")
        let dotted = Aggregator.alias(server: "files", name: "read.file")
        #expect(dotted.hasPrefix("files__read_file_"))
        #expect(dotted != Aggregator.alias(server: "files", name: "read_file"))
        let long = Aggregator.alias(server: "server", name: String(repeating: "x", count: 80))
        #expect(long.count == 64)
        #expect(long != Aggregator.alias(server: "server", name: String(repeating: "x", count: 81)))
        #expect(long.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
    }
}

@Suite struct ConfigTests {
    @Test func namesAndSlugs() {
        #expect(ServerConfig.isValidName("github"))
        #expect(ServerConfig.isValidName("my-server-2"))
        #expect(!ServerConfig.isValidName("My Server"))
        #expect(!ServerConfig.isValidName("a__b"))
        #expect(!ServerConfig.isValidName("-x"))
        #expect(ServerConfig.slug("My GitHub (work)") == "my-github-work")
        #expect(ServerConfig.slug("___") == "server")
        #expect(ServerConfig.uniqueName("files", taken: ["files", "files-2"]) == "files-3")
    }

    @Test func suggestsNamesFromCommands() {
        let suggest = { ServerConfig.suggestedName(for: splitCommandLine($0)) }
        #expect(suggest("npx -y @modelcontextprotocol/server-filesystem ~/Docs") == "filesystem")
        #expect(suggest("uvx mcp-server-git --repository /tmp/x") == "git")
        #expect(suggest("npx @playwright/mcp@latest") == "playwright")
        #expect(suggest("docker run -i --rm ghcr.io/github/github-mcp-server") == "github")
        #expect(suggest("/usr/local/bin/my-tool-mcp") == "my-tool")
        #expect(suggest("") == "")
    }

    @Test func commandLineRoundTrips() {
        var config = ServerConfig(name: "fs", command: "npx", args: ["-y", "@scope/server", "/Users/me/My Docs"])
        #expect(config.commandLineString == "npx -y @scope/server '/Users/me/My Docs'")
        config.commandLineString = "uvx mcp-server-git --repository \"/tmp/a b\""
        #expect(config.command == "uvx")
        #expect(config.args == ["mcp-server-git", "--repository", "/tmp/a b"])
    }

    @Test func storeRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "porchlight-\(UUID())/servers.json")
        let store = ServerStore(url: url)
        #expect(store.load() == nil)
        let servers = [ServerConfig(name: "a", command: "x", env: ["TOKEN": "secret"])]
        try store.save(servers)
        #expect(store.load() == servers)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func importsFromOtherApps() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "porchlight-home-\(UUID())")
        let write = { (path: String, json: String) in
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: url)
        }
        try write("Library/Application Support/Claude/claude_desktop_config.json", #"""
            {"mcpServers": {"Git Hub": {"command": "npx", "args": ["-y", "gh-mcp"], "env": {"TOKEN": "t"}}}}
            """#)
        try write(".claude.json", #"""
            {"mcpServers": {"remote": {"type": "http", "url": "https://example.com/mcp"}},
             "projects": {"/code/app": {"mcpServers": {"db": {"type": "stdio", "command": "uvx", "args": ["db-mcp"]}}}}}
            """#)
        try write(".cursor/mcp.json", #"{"mcpServers": {"fs": {"command": "fs-mcp"}}}"#)

        let found = ConfigImporter.candidates(home: home)
        #expect(found.map(\.originalName) == ["Git Hub", "remote", "db", "fs"])

        let github = try #require(found.first?.config)
        #expect(github.name == "git-hub")
        #expect(github.commandLine == ["npx", "-y", "gh-mcp"])
        #expect(github.env == ["TOKEN": "t"])

        #expect(found[1].config == nil)
        #expect(found[1].unsupportedReason == "Remote server: add it to your AI app directly")
        #expect(found[2].source == .claudeCode)
        #expect(found[2].scope == "/code/app")
        #expect(found[3].source == .cursor)
    }
}

@Suite struct ProtocolTests {
    @Test func integerIDsRoundTripExactly() throws {
        let value = try JSONValue.parse(Data(#"{"id":1,"x":1.5,"big":9007199254740993}"#.utf8))
        #expect(value["id"] == .int(1))
        #expect(value["big"] == .int(9007199254740993))
        let text = String(decoding: value.serialized(), as: UTF8.self)
        #expect(text.contains(#""id":1"#))
        #expect(!text.contains("1.0"))
    }

    @Test func decodesRequestFrames() throws {
        let frame = RelayFrame.decode(#"{"type":"req","id":"r1","method":"POST","path":"/mcp?a=b","headers":[["accept","text/event-stream"]],"body_b64":"e30="}"#)
        guard case .req(let request) = frame else {
            Issue.record("expected req, got \(frame)")
            return
        }
        #expect(request.route == "/mcp")
        #expect(request.header("Accept") == "text/event-stream")
        #expect(request.body == Data("{}".utf8))
        if case .cancel(let id) = RelayFrame.decode(#"{"type":"cancel","id":"r1"}"#) {
            #expect(id == "r1")
        } else {
            Issue.record("expected cancel")
        }
        if case .pong = RelayFrame.decode(RelayProtocol.pong) {} else { Issue.record("expected pong") }
    }

    @Test func decodesPairingAndClientFrames() throws {
        let pairing = RelayFrame.decode(#"{"type":"pair_request","id":"p1","code":"048213","client_name":"Claude","client_domain":"claude.ai","redirect_host":"claude.ai","loopback":false}"#)
        guard case .event(.pairingRequested(let request)) = pairing else {
            Issue.record("expected pairing request, got \(pairing)")
            return
        }
        #expect(request.id == "p1")
        #expect(request.formattedCode == "048 213")
        #expect(request.clientDomain == "claude.ai")
        #expect(!request.loopback)

        let clients = RelayFrame.decode(#"{"type":"clients","items":[{"grant_id":"g1","client_id":"https://claude.ai/oauth/client","client_name":"Claude","created_at":1760000000}]}"#)
        guard case .event(.clientsChanged(let items)) = clients else {
            Issue.record("expected clients, got \(clients)")
            return
        }
        #expect(items.map(\.id) == ["g1"])
        #expect(items.first?.createdAt == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(HostFrame.pairDecision(id: "p1", allow: true).contains(#""allow":true"#))
    }

    @Test func splitsCommandLines() {
        #expect(splitCommandLine(#"npx -y "a b" 'c d' e\ f"#) == ["npx", "-y", "a b", "c d", "e f"])
        #expect(splitCommandLine("  ") == [])
        #expect(splitCommandLine(#"x """#) == ["x", ""])
    }

    @Test func parsesShellEnvironment() {
        let output = Data("motd noise __PORCHLIGHT_ENV__PATH=/a:/b\0HOME=/Users/x\0EMPTY=\0".utf8)
        let env = ShellEnvironment.parse(output, after: "__PORCHLIGHT_ENV__")
        #expect(env == ["PATH": "/a:/b", "HOME": "/Users/x", "EMPTY": ""])
    }
}
