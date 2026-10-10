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

func fakeServer() -> StdioBridge {
    let script = Bundle.module.path(forResource: "fake_server", ofType: "py", inDirectory: "Fixtures")!
    return StdioBridge(name: "fake", command: ["python3", "-u", script], log: { _ in })
}

@discardableResult
func post(
    _ bridge: StdioBridge,
    _ body: String,
    path: String = "/mcp",
    accept: String = "application/json, text/event-stream"
) async -> RecordedResponse {
    let recorded = RecordedResponse()
    let request = HTTPRequest(
        id: UUID().uuidString, method: "POST", path: path,
        headers: [("accept", accept), ("content-type", "application/json")],
        body: Data(body.utf8)
    )
    await bridge.handle(request, recorded.responder)
    return recorded
}

let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#

func callTool(id: Int, _ name: String, _ args: String = "{}") -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#
}

/// The `text` of the first content block in a tools/call result.
func toolText(_ response: JSONValue?) -> JSONValue? {
    guard case .array(let content)? = response?["result"]?["content"],
          let text = content.first?["text"]?.stringValue
    else { return nil }
    return try? JSONValue.parse(Data(text.utf8))
}

/// Parses the `data:` lines of an SSE body.
func sseMessages(_ body: String) -> [JSONValue] {
    body.split(separator: "\n")
        .filter { $0.hasPrefix("data: ") }
        .compactMap { try? JSONValue.parse(Data($0.dropFirst(6).utf8)) }
}

@Suite struct StdioBridgeTests {
    @Test func initializesAndKeepsClientIDs() async throws {
        let bridge = fakeServer()
        defer { Task { await bridge.stop() } }

        let initialized = await post(bridge, initialize)
        #expect(await initialized.status == 200)
        #expect(await initialized.json?["id"] == .int(0))
        #expect(await initialized.json?["result"]?["serverInfo"]?["name"] == .string("fake"))

        let list = await post(bridge, #"{"jsonrpc":"2.0","id":"abc","method":"tools/list"}"#)
        #expect(await list.json?["id"] == .string("abc"))
        #expect(await list.header("content-type") == "application/json")
    }

    @Test func clientsReusingAnIDDoNotCollide() async throws {
        let bridge = fakeServer()
        defer { Task { await bridge.stop() } }
        await post(bridge, initialize)

        async let a = post(bridge, callTool(id: 1, "echo", #"{"who":"a"}"#), accept: "application/json")
        async let b = post(bridge, callTool(id: 1, "echo", #"{"who":"b"}"#), accept: "application/json")
        let (ra, rb) = await (a, b)

        let ea = toolText(await ra.json), eb = toolText(await rb.json)
        #expect(await ra.json?["id"] == .int(1))
        #expect(await rb.json?["id"] == .int(1))
        #expect(ea?["args"]?["who"] == .string("a"))
        #expect(eb?["args"]?["who"] == .string("b"))
        // The child saw two distinct internal ids.
        #expect(ea?["id"] != eb?["id"])
    }

    @Test func answersRepeatInitializeFromCache() async throws {
        let bridge = fakeServer()
        defer { Task { await bridge.stop() } }
        await post(bridge, initialize)
        let again = await post(bridge, initialize.replacingOccurrences(of: #""id":0"#, with: #""id":9"#))
        #expect(await again.json?["id"] == .int(9))

        let stats = await post(bridge, callTool(id: 2, "stats"), accept: "application/json")
        #expect(toolText(await stats.json)?["initialize_count"] == .int(1))
    }

    @Test func streamsToolCallsWithProgress() async throws {
        let bridge = fakeServer()
        defer { Task { await bridge.stop() } }
        await post(bridge, initialize)

        let call = #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"slow","arguments":{"seconds":0.1},"_meta":{"progressToken":"tok"}}}"#
        let response = await post(bridge, call)
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

    @Test func restartsACrashedServerAndReplaysInitialize() async throws {
        let bridge = fakeServer()
        defer { Task { await bridge.stop() } }
        await post(bridge, initialize)

        let crashed = await post(bridge, callTool(id: 3, "crash"), accept: "application/json")
        #expect(await crashed.json?["error"]?["message"] == .string("fake exited"))

        // The client never re-initializes; the bridge does it for the new process.
        let stats = await post(bridge, callTool(id: 4, "stats"), accept: "application/json")
        #expect(toolText(await stats.json)?["initialize_count"] == .int(1))
        #expect(await stats.json?["id"] == .int(4))
    }

    @Test func httpEdges() async throws {
        let bridge = fakeServer()
        defer { Task { await bridge.stop() } }

        let notification = await post(bridge, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(await notification.status == 202)

        let badJSON = await post(bridge, "{nope")
        #expect(await badJSON.status == 400)
        #expect(await badJSON.json?["error"]?["code"] == .int(-32700))

        let wrongServer = await post(bridge, initialize, path: "/s/other/mcp")
        #expect(await wrongServer.status == 404)
        let perServer = await post(bridge, initialize, path: "/s/fake/mcp?x=1")
        #expect(await perServer.status == 200)

        let get = RecordedResponse()
        await bridge.handle(HTTPRequest(id: "g", method: "GET", path: "/mcp"), get.responder)
        #expect(await get.status == 405)
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
}
