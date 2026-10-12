import Foundation
import Testing
@testable import PorchlightCore

@Suite struct SecurityTests {
    private func queued(_ router: Router, _ tool: String) async -> JSONValue? {
        let recorded = RecordedResponse()
        await router.handle(HTTPRequest(
            id: UUID().uuidString, method: "POST", path: "/mcp",
            headers: [
                ("accept", "application/json"), ("porchlight-client-name", "Claude"),
                (Router.queuedAtHeader, Date().formatted(.iso8601)),
            ],
            body: Data(callTool(id: 1, tool).utf8)
        ), recorded.responder)
        return await recorded.json
    }

    /// The relay queues by the catalog it was last sent, which can be out of date.
    @Test func queuedCallsRunOnlyIfTheToolStillQueues() async {
        var policy = ToolPolicy(defaultPermission: .allowAll)
        policy.offline["add"] = false
        let harness = await PolicyHarness([queueConfig("alpha", policy: policy)], answer: .allowOnce)
        defer { Task { await harness.router.stopAll() } }

        for tool in ["alpha__add", "alpha__remove", "alpha__echo"] {
            let response = await queued(harness.router, tool)
            #expect(response?["result"]?["isError"] == .bool(true), "\(tool) ran")
        }
        #expect(harness.activity.value.allSatisfy { if case .denied = $0.outcome { true } else { false } })
    }

    @Test func callsThatCantBePlacedNeverRun() async {
        let harness = await PolicyHarness([fakeConfig("alpha")])
        defer { Task { await harness.router.stopAll() } }

        let unknown = await postAs("Claude", harness.router, callTool(id: 1, "alpha__nope")).json
        #expect(unknown?["error"]?["code"] == .int(-32602))
        let nameless = await postAs("Claude", harness.router, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":7}}"#).json
        #expect(nameless?["error"]?["code"] == .int(-32602))
        let passthrough = await postAs(
            "Claude", harness.router, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{}}"#, path: "/mcp/alpha"
        ).json
        #expect(passthrough?["error"]?["code"] == .int(-32602))
    }

    @Test func appNamesStayOnOnePlainLine() {
        #expect(displayName("Claude\nPublished by claude.ai") == "Claude Published by claude.ai")
        #expect(displayName("  Chat\u{202E}GPT\u{200B} ") == "ChatGPT")
        #expect(displayName(String(repeating: "a", count: 200)).count == 80)
        let frame = RelayFrame.decode(#"{"type":"pair_request","id":"p","code":"123456","client_name":"Evil Line","redirect_host":"x.test","loopback":false}"#)
        guard case .event(.pairingRequested(let request)) = frame else {
            Issue.record("expected pair_request, got \(frame)")
            return
        }
        #expect(request.clientName == "Evil Line")
    }

    @Test func logsMaskCredentials() {
        #expect(loggableCommandLine(["npx", "server", "--api-key", "sk-123", "--token=abc", "--port", "80"])
            == "npx server --api-key *** --token=*** --port 80")
        #expect(loggableCommandLine(["uvx", "srv", "https://h.test/mcp?token=abc"]) == "uvx srv 'https://h.test/mcp?***'")
        #expect(loggableURL("https://user:pw@h.test/mcp") == "https://user:***@h.test/mcp")
        #expect(loggableURL("http://127.0.0.1:27123/mcp") == "http://127.0.0.1:27123/mcp")
    }

    @Test func settingsThatReferToThemselvesStop() {
        let resolver = PlaceholderResolver(directory: "/x", home: "/h", values: ["a": .string("${user_config.a}")])
        #expect(throws: PlaceholderResolver.Missing.self) { try resolver.resolve("${user_config.a}") }
        let nested = PlaceholderResolver(directory: "/x", home: "/h", values: ["dir": .string("${HOME}/Documents")])
        #expect((try? nested.resolve("${user_config.dir}")) == "/h/Documents")
    }

    @Test func iconsComeOnlyFromPublicHTTPS() {
        let html = """
        <link rel="icon" href="http://example.com/a.png">
        <link rel="icon" href="https://192.168.1.1/b.png">
        <link rel="icon" href="https://router.local/c.png">
        <link rel="icon" href="https://localhost/d.png">
        <link rel="icon" href="https://[::1]/e.png">
        <link rel="icon" href="https://cdn.example.com/f.png">
        """
        let found = SiteIcon.candidates(html: html, base: URL(string: "https://example.com/")!)
        #expect(found.map(\.absoluteString) == ["https://cdn.example.com/f.png"])
    }

    @Test func httpServersRedirectOnlyWithinTheirOrigin() {
        let origin = URL(string: "https://mcp.example.com/mcp")
        #expect(LoopbackTrust.sameOrigin(origin, URL(string: "https://MCP.example.com:443/v2")))
        #expect(!LoopbackTrust.sameOrigin(origin, URL(string: "https://evil.test/mcp")))
        #expect(!LoopbackTrust.sameOrigin(origin, URL(string: "http://mcp.example.com/mcp")))
        #expect(!LoopbackTrust.sameOrigin(origin, URL(string: "https://mcp.example.com:8443/mcp")))
    }
}
