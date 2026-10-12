import Foundation
import Testing
@testable import PorchlightCore

/// One server as-is, at `/mcp/<name>`.
@Suite struct PassthroughTests {
    @Test func initializesAndKeepsClientIDs() async {
        await withRouter([fakeConfig("fake")]) { h in
            let initialized = await h.post(initialize, path: "/mcp/fake")
            #expect(await initialized.status == 200)
            #expect(await initialized.json?["id"] == .int(0))
            #expect(await initialized.json?["result"]?["serverInfo"]?["name"] == .string("fake"))

            let list = await h.post(#"{"jsonrpc":"2.0","id":"abc","method":"tools/list"}"#, path: "/mcp/fake")
            #expect(await list.json?["id"] == .string("abc"))
            #expect(await list.header("content-type") == "application/json")
        }
    }

    @Test func clientsReusingAnIDDoNotCollide() async {
        await withRouter([fakeConfig("fake")]) { h in
            async let a = h.post(callTool(id: 1, "echo", #"{"who":"a"}"#), path: "/mcp/fake")
            async let b = h.post(callTool(id: 1, "echo", #"{"who":"b"}"#), path: "/mcp/fake")
            let (ra, rb) = await (a, b)

            let ea = toolText(await ra.json), eb = toolText(await rb.json)
            #expect(await ra.json?["id"] == .int(1))
            #expect(await rb.json?["id"] == .int(1))
            #expect(ea?["args"]?["who"] == .string("a"))
            #expect(eb?["args"]?["who"] == .string("b"))
            // The child saw two distinct internal ids.
            #expect(ea?["id"] != eb?["id"])
        }
    }

    @Test func clientInitializeIsAnsweredFromPorchlightsHandshake() async {
        await withRouter([fakeConfig("fake")]) { h in
            await h.post(initialize, path: "/mcp/fake")
            let again = await h.post(initialize.replacingOccurrences(of: #""id":0"#, with: #""id":9"#), path: "/mcp/fake")
            #expect(await again.json?["id"] == .int(9))

            let stats = await h.post(callTool(id: 2, "stats"), path: "/mcp/fake")
            #expect(toolText(await stats.json)?["initialize_count"] == .int(1))
        }
    }

    @Test func streamsToolCallsWithProgress() async {
        await withRouter([fakeConfig("fake")]) { h in
            let call = rpc(5, "tools/call", #"{"name":"slow","arguments":{"seconds":0.1},"_meta":{"progressToken":"tok"}}"#)
            let response = await h.post(call, path: "/mcp/fake", accept: "application/json, text/event-stream")
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
    }

    @Test func restartsACrashedServerTransparently() async {
        await withRouter([fakeConfig("fake")]) { h in
            let crashed = await h.post(callTool(id: 3, "crash"), path: "/mcp/fake")
            #expect(await crashed.json?["error"]?["message"] == .string("fake exited"))

            // The app never re-initializes; Porchlight does it for the new process.
            let stats = await h.post(callTool(id: 4, "stats"), path: "/mcp/fake")
            #expect(toolText(await stats.json)?["initialize_count"] == .int(1))
            #expect(await stats.json?["id"] == .int(4))
            // The next request restarts it, possibly before the exit code is known.
            let statuses = h.statuses.value["fake"] ?? []
            #expect(statuses.contains { if case .failed(let reason) = $0 { reason.hasPrefix("Exited") } else { false } })
            #expect(statuses.last == .running)
        }
    }

    @Test func reportsTheExitCodeOfACrashedServer() async throws {
        try await withRouter([fakeConfig("fake")]) { h in
            await h.post(callTool(id: 1, "crash"), path: "/mcp/fake")
            // The exit status arrives a moment after the output ends.
            let deadline = ContinuousClock.now + .seconds(2)
            while h.statuses.value["fake"]?.last != .failed("Exited with status 1"), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(h.statuses.value["fake"]?.last == .failed("Exited with status 1"))
        }
    }

    @Test func httpEdges() async {
        await withRouter([fakeConfig("fake")]) { h in
            let notification = await h.post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, path: "/mcp/fake")
            #expect(await notification.status == 202)

            let badJSON = await h.post("{nope", path: "/mcp/fake")
            #expect(await badJSON.status == 400)
            #expect(await badJSON.json?["error"]?["code"] == .int(-32700))

            let unknown = await h.post(initialize, path: "/mcp/other")
            #expect(await unknown.status == 404)
            let withQuery = await h.post(initialize, path: "/mcp/fake?x=1")
            #expect(await withQuery.status == 200)

            let get = RecordedResponse()
            await h.router.handle(HTTPRequest(id: "g", method: "GET", path: "/mcp"), get.responder)
            #expect(await get.status == 405)
        }
    }

    @Test func answersBatchesItemByItem() async {
        await withRouter([fakeConfig("fake")]) { h in
            let batch = "[\(callTool(id: 1, "echo", #"{"n":1}"#)),\(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#),\(rpc(2, "tools/list"))]"
            let response = await h.post(batch, path: "/mcp/fake")
            guard case .array(let replies)? = await response.json else {
                Issue.record("expected a batch reply")
                return
            }
            #expect(replies.map(\.rpcID) == [.int(1), .int(2)])
            #expect(toolText(replies[0])?["args"]?["n"] == .int(1))
        }
    }
}
