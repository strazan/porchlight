import Foundation
import Testing
@testable import PorchlightCore

/// Servers already listening for Streamable HTTP, like Obsidian's.
@Suite struct HTTPUpstreamTests {
    @Test func servesAnHTTPServerPerServerAndCombined() async throws {
        let server = try FakeHTTPServer()
        await withRouter([httpConfig("obsidian", url: server.url), fakeConfig("alpha")]) { h in
            let initialized = await h.post(initialize, path: "/mcp/obsidian")
            #expect(await initialized.json?["result"]?["serverInfo"]?["name"] == .string("fake-http"))

            let list = await h.post(rpc(1, "tools/list"))
            #expect(names(await list.json, "tools") == ["obsidian__search", "alpha__echo"])

            let call = await h.post(callTool(id: 2, "obsidian__search", #"{"q":"porch"}"#))
            #expect(await call.json?["id"] == .int(2))
            let echoed = toolText(await call.json)
            #expect(echoed?["args"]?["q"] == .string("porch"))
            // After initialize, requests carry the negotiated protocol version.
            #expect(echoed?["protocol"] == .string("2025-06-18"))
        }
    }

    @Test func forwardsSSEProgress() async throws {
        let server = try FakeHTTPServer()
        await withRouter([httpConfig("obsidian", url: server.url)]) { h in
            let call = rpc(3, "tools/call", #"{"name":"search","arguments":{},"_meta":{"progressToken":"p"}}"#)
            let response = await h.post(call, path: "/mcp/obsidian", accept: "application/json, text/event-stream")
            let messages = sseMessages(await response.text)
            #expect(messages.first?["method"] == .string("notifications/progress"))
            #expect(messages.last?["id"] == .int(3))
            #expect(messages.last?["result"] != nil)
        }
    }

    @Test func readsMessagesSplitOverSeveralDataLines() async throws {
        let server = try FakeHTTPServer()
        await withRouter([httpConfig("obsidian", url: server.url)]) { h in
            let call = await h.post(callTool(id: 4, "split", #"{"q":"porch"}"#), path: "/mcp/obsidian", accept: "application/json, text/event-stream")
            let messages = sseMessages(await call.text)
            #expect(toolText(messages.last)?["args"]?["q"] == .string("porch"))
        }
    }

    @Test func reconnectsWhenTheServerForgetsTheSession() async throws {
        let server = try FakeHTTPServer()
        await withRouter([httpConfig("obsidian", url: server.url)]) { h in
            await h.post(callTool(id: 1, "restart"), path: "/mcp/obsidian")
            // The old session is gone; Porchlight initializes again and retries.
            let stats = await h.post(callTool(id: 2, "stats"), path: "/mcp/obsidian")
            #expect(toolText(await stats.json)?["initialize_count"] == .int(2))
        }
    }

    @Test func reportsAuthAndConnectionFailures() async throws {
        let server = try FakeHTTPServer()
        let servers = [httpConfig("wrongkey", url: server.url, key: "nope"), ServerConfig(name: "closed", url: "http://127.0.0.1:9/mcp")]
        await withRouter(servers) { h in
            let refused = await h.post(rpc(1, "tools/list"), path: "/mcp/wrongkey")
            #expect(await refused.json?.failure?.contains("Authorization") == true)
            let closed = await h.post(rpc(1, "tools/list"), path: "/mcp/closed")
            #expect(await closed.json?["error"] != nil)
            #expect(h.statuses.value["closed"]?.last.map { if case .failed = $0 { true } else { false } } == true)

            // The combined endpoint still answers, without them.
            let list = await h.post(rpc(2, "tools/list"))
            #expect(names(await list.json, "tools") == [])
        }
    }

    @Test func reportsAURLThatDoesntParse() async {
        await withRouter([ServerConfig(name: "typo", url: "not a url")]) { h in
            let response = await h.post(rpc(1, "tools/list"), path: "/mcp/typo")
            #expect(await response.json?.failure?.contains("URL") == true)
        }
    }

    @Test func probesAConfigBeforeSaving() async throws {
        let server = try FakeHTTPServer()
        let good = await ServerProbe.run(httpConfig("obsidian", url: server.url), environment: [:])
        guard case .success(let found) = good else {
            Issue.record("expected the probe to succeed, got \(good)")
            return
        }
        #expect(found.serverName == "fake-http")
        #expect(found.tools.map(\.name) == ["search"])
        #expect(found.tools.first?.hints.readOnly == false)

        guard case .failure(let error) = await ServerProbe.run(httpConfig("obsidian", url: server.url, key: "nope"), environment: [:]) else {
            Issue.record("expected the wrong key to fail")
            return
        }
        #expect(error.message.contains("Authorization"))
    }

}
