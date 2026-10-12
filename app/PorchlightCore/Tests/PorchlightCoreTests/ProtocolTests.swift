import Foundation
import Testing
@testable import PorchlightCore

/// JSON, the relay's frames, and parsing helpers.
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
        let pairing = RelayFrame.decode(#"{"type":"pair_request","id":"p1","code":"048213","client_id":"https://claude.ai/oauth/client","client_name":"Claude","client_domain":"claude.ai","redirect_host":"claude.ai","loopback":false}"#)
        guard case .event(.pairingRequested(let request)) = pairing else {
            Issue.record("expected pairing request, got \(pairing)")
            return
        }
        #expect(request.id == "p1")
        #expect(request.clientID == "https://claude.ai/oauth/client")
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

    @Test func encodesResponseFrames() throws {
        let start = try JSONValue.parse(Data(HostFrame.resStart(id: "r1", status: 200, headers: [("content-type", "text/event-stream")]).utf8))
        #expect(start == .object([
            "type": .string("res_start"), "id": .string("r1"), "status": .int(200),
            "headers": .array([.array([.string("content-type"), .string("text/event-stream")])]),
        ]))
        let chunk = try JSONValue.parse(Data(HostFrame.resChunk(id: "r1", data: Data("hi".utf8)).utf8))
        #expect(chunk["data_b64"] == .string("aGk="))
        #expect(try JSONValue.parse(Data(HostFrame.resEnd(id: "r1").utf8)) == .object(["type": .string("res_end"), "id": .string("r1")]))
    }
}
