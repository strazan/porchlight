import Foundation
import Testing
@testable import PorchlightCore

/// Defenses: what keeps a call, an app or a page from doing more than it should.
@Suite struct SecurityTests {
    /// The relay queues by the catalog it was last sent, which can be out of date.
    @Test func queuedCallsRunOnlyIfTheToolStillQueues() async {
        var policy = ToolPolicy(defaultPermission: .allowAll)
        policy.offline["add"] = false
        await withRouter([queueConfig("alpha", policy: policy)], answer: .allowOnce) { h in
            for tool in ["alpha__add", "alpha__remove", "alpha__echo"] {
                let response = await h.post(callTool(id: 1, tool), from: .claude, queuedAt: Date())
                #expect(await response.json?["result"]?["isError"] == .bool(true), "\(tool) ran")
            }
            #expect(h.activity.value.allSatisfy { if case .denied = $0.outcome { true } else { false } })
        }
    }

    @Test func callsThatCantBePlacedNeverRun() async {
        await withRouter([fakeConfig("alpha")]) { h in
            let unknown = await h.post(callTool(id: 1, "alpha__nope"), from: .claude).json
            #expect(unknown?["error"]?["code"] == .int(-32602))
            let nameless = await h.post(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":7}}"#, from: .claude).json
            #expect(nameless?["error"]?["code"] == .int(-32602))
            let passthrough = await h.post(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{}}"#, path: "/mcp/alpha", from: .claude).json
            #expect(passthrough?["error"]?["code"] == .int(-32602))
        }
    }

    @Test func appNamesStayOnOnePlainLine() {
        #expect("Claude\nPublished by claude.ai".displayName() == "Claude Published by claude.ai")
        #expect("  Chat\u{202E}GPT\u{200B} ".displayName() == "ChatGPT")
        #expect(String(repeating: "a", count: 200).displayName().count == 80)
        #expect(ClientIdentity(id: "x", name: "Evil\nLine").name == "Evil Line")
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
        #expect(HTTPUpstreamDelegate.sameOrigin(origin, URL(string: "https://MCP.example.com:443/v2")))
        #expect(!HTTPUpstreamDelegate.sameOrigin(origin, URL(string: "https://evil.test/mcp")))
        #expect(!HTTPUpstreamDelegate.sameOrigin(origin, URL(string: "http://mcp.example.com/mcp")))
        #expect(!HTTPUpstreamDelegate.sameOrigin(origin, URL(string: "https://mcp.example.com:8443/mcp")))
    }

    @Test func classifiesHosts() {
        #expect(Hosts.isLoopback("[::1]") && Hosts.isLoopback("LOCALHOST"))
        #expect(Hosts.isLocal("192.168.1.20") && Hosts.isLocal("printer.local") && Hosts.isLocal("172.20.0.1"))
        #expect(!Hosts.isLocal("172.40.0.1") && !Hosts.isLocal("example.com"))
        #expect(Hosts.isPublicName("cdn.example.com"))
        #expect(!Hosts.isPublicName("10.0.0.1") && !Hosts.isPublicName("router.lan") && !Hosts.isPublicName("intranet"))
    }
}
