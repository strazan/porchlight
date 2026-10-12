import Foundation
import Testing
@testable import PorchlightCore

/// Requests saved by the relay while the Mac was offline.
@Suite struct QueueTests {
    /// The shared vector in protocol/vectors, sealed by WebCrypto the way the relay does it.
    @Test func opensWhatTheRelaySeals() throws {
        let file = repositoryRoot.appending(path: "protocol/vectors/queue.json")
        let vector = try JSONValue.parse(Data(contentsOf: file))
        let d = try #require(vector["private_key"]?["d"]?.stringValue)
        var base64 = d.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let key = try QueueKey(rawRepresentation: try #require(Data(base64Encoded: base64)))
        let sealed = try #require(vector["sealed"]?.stringValue.flatMap { Data(base64Encoded: $0) })
        let id = try #require(vector["id"]?.stringValue)

        let opened = try key.open(sealed, associated: id)
        #expect(String(decoding: opened, as: UTF8.self) == vector["plaintext"]?.stringValue)
        // Bound to its id, and to this key.
        #expect(throws: (any Error).self) { try key.open(sealed, associated: "another-id") }
        #expect(throws: (any Error).self) { try QueueKey().open(sealed, associated: id) }
    }

    @Test func keysSurviveTheKeychain() throws {
        let key = QueueKey()
        #expect(Data(base64Encoded: key.publicKey)?.count == 65)
        #expect(try QueueKey(rawRepresentation: key.rawRepresentation).publicKey == key.publicKey)
    }

    @Test func onlyAdditiveToolsQueueByDefault() {
        var policy = ToolPolicy(defaultPermission: .askForChanges)
        #expect(policy.queuesOffline("add", readOnly: false, destructive: false))
        #expect(!policy.queuesOffline("read", readOnly: true, destructive: false))
        #expect(!policy.queuesOffline("remove", readOnly: false, destructive: true))

        policy.offline = ["remove": true, "add": false]
        #expect(policy.queuesOffline("remove", readOnly: false, destructive: true))
        #expect(!policy.queuesOffline("add", readOnly: false, destructive: false))
        policy.overrides["remove"] = .deny
        #expect(!policy.queuesOffline("remove", readOnly: false, destructive: true))
    }

    @Test func catalogShowsWhatTheAppSeesAndWhatQueues() async {
        var blocking = ToolPolicy(defaultPermission: .allowAll)
        blocking.overrides["add"] = .deny
        await withRouter([queueConfig("alpha"), queueConfig("beta", policy: blocking)], access: ["chatgpt": ["alpha"]]) { h in
            let scoped = await h.router.offlineCatalog(for: "chatgpt")
            guard case .object(let paths)? = scoped["paths"] else {
                Issue.record("no paths")
                return
            }
            #expect(Set(paths.keys) == ["/mcp", "/mcp/alpha"])
            #expect(names(.object(["result": paths["/mcp"] ?? .null]), "tools") == ["alpha__echo", "alpha__add", "alpha__remove"])
            #expect(paths["/mcp"]?["queueable"] == .array([.string("alpha__add")]))
            #expect(paths["/mcp/alpha"]?["queueable"] == .array([.string("add")]))
            #expect(paths["/mcp/alpha"]?["initialize"]?["serverInfo"]?["name"] == .string("alpha"))
            #expect(scoped["protocol_versions"]?.stringArray?.contains("2025-06-18") == true)

            // An app without limits sees beta too, minus its blocked tool, which never queues.
            let everything = await h.router.offlineCatalog(for: "claude")
            let beta = everything["paths"]?["/mcp/beta"]
            #expect(names(.object(["result": beta ?? .null]), "tools") == ["echo", "remove"])
            #expect(beta?["queueable"] == .array([]))
        }
    }

    @Test func queuedCallsAskWithTheTimeTheyWereMade() async {
        let made = Date(timeIntervalSince1970: 1_800_000_000)
        await withRouter([queueConfig("alpha", policy: ToolPolicy(defaultPermission: .askForChanges))], answer: .allowOnce) { h in
            let response = await h.post(callTool(id: 1, "alpha__add"), from: .claude, queuedAt: made)
            #expect(toolText(await response.json)?["server"] == .string("alpha"))
            #expect(h.asked.value.map(\.queuedAt) == [made])
            #expect(h.activity.value.last?.queuedAt == made)
        }
    }

    @Test func ledgerRemembersFinishedRequests() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "porchlight-ledger-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let ledger = QueueLedger(file: file)
        ledger.add("a")
        ledger.add("a")
        #expect(ledger.contains("a"))
        #expect(QueueLedger(file: file).contains("a"))
        for i in 0..<QueueLedger.limit { ledger.add("n\(i)") }
        #expect(!QueueLedger(file: file).contains("a"))

        // A list that can't be read starts over, and says so.
        try Data("garbage".utf8).write(to: file)
        let logged = Locked<[String]>([])
        #expect(!QueueLedger(file: file, log: { line in logged.withLock { $0.append(line) } }).contains("n1"))
        #expect(logged.value.count == 1)
    }

    @Test func framesCarryQueuedRequests() throws {
        let frame = RelayFrame.decode(#"{"type":"queued","id":"q1","client_id":"c","client_name":"Claude","path":"/mcp","queued_at":1800000000000,"sealed":"AAEC"}"#)
        guard case .queued(let item) = frame else {
            Issue.record("expected queued, got \(frame)")
            return
        }
        #expect(item == QueuedRequest(
            id: "q1", clientID: "c", clientName: "Claude", path: "/mcp",
            queuedAt: Date(timeIntervalSince1970: 1_800_000_000), sealed: Data([0, 1, 2])
        ))
        let hello = try JSONValue.parse(Data(HostFrame.hello(appVersion: "t", queueKey: "KEY").utf8))
        #expect(hello["queue_key"] == .string("KEY"))
        #expect(try JSONValue.parse(Data(HostFrame.hello(appVersion: "t").utf8))["queue_key"] == nil)
    }
}

private extension JSONValue {
    var stringArray: [String]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap(\.stringValue)
    }
}
