import Foundation
import Testing
@testable import PorchlightCore

/// A router whose approvals and activity are recorded, with a scripted answer.
struct PolicyHarness {
    let router: Router
    let asked = Locked<[ToolApprovalRequest]>([])
    let activity = Locked<[ActivityEvent]>([])

    init(_ servers: [ServerConfig], answer: ToolApproval = .deny) async {
        let asked = self.asked
        let activity = self.activity
        router = Router(
            environment: ProcessInfo.processInfo.environment,
            log: { _, _ in },
            approve: { request in
                asked.withLock { $0.append(request) }
                return answer
            },
            onActivity: { event in activity.withLock { $0.append(event) } }
        )
        await router.apply(servers)
    }
}

/// A request as the relay forwards it, with the client's identity.
func postAs(_ client: String, _ router: Router, _ body: String, path: String = "/mcp") async -> RecordedResponse {
    let recorded = RecordedResponse()
    let request = HTTPRequest(
        id: UUID().uuidString, method: "POST", path: path,
        headers: [("accept", "application/json"), ("porchlight-client-name", client.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)],
        body: Data(body.utf8)
    )
    await router.handle(request, recorded.responder)
    return recorded
}

@Suite struct PolicyTests {
    let askForChanges = ToolPolicy(defaultPermission: .askForChanges)

    @Test func readOnlyToolsRunAndOthersAsk() async {
        let harness = await PolicyHarness([fakeConfig("alpha", policy: askForChanges)])
        defer { Task { await harness.router.stopAll() } }

        let echo = await postAs("Claude", harness.router, callTool(id: 1, "alpha__echo"))
        #expect(toolText(await echo.json)?["server"] == .string("alpha"))
        #expect(harness.asked.value.isEmpty)

        // `stats` isn't listed (so not marked read-only): it needs approval, and the answer is no.
        let stats = await postAs("Claude", harness.router, callTool(id: 2, "stats"), path: "/mcp/alpha")
        #expect(await stats.json?["id"] == .int(2))
        #expect(GatedEndpoint.text(of: await stats.json ?? .null)?.contains("declined") == true)
        #expect(await stats.json?["result"]?["isError"] == .bool(true))
        let asked = harness.asked.value
        #expect(asked.map(\.tool) == ["stats"])
        #expect(asked.first?.server == "alpha")
        #expect(asked.first?.clientName == "Claude")
    }

    @Test func approvedCallsGoThrough() async {
        let harness = await PolicyHarness([fakeConfig("alpha", policy: askForChanges)], answer: .allowOnce)
        defer { Task { await harness.router.stopAll() } }
        let stats = await post(harness.router, callTool(id: 1, "stats"), path: "/mcp/alpha")
        #expect(toolText(await stats.json)?["initialize_count"] == .int(1))
        #expect(harness.asked.value.count == 1)
    }

    @Test func deniedToolsAreHiddenAndBlocked() async {
        let policy = ToolPolicy(defaultPermission: .allowAll, overrides: ["echo": .deny])
        let harness = await PolicyHarness([fakeConfig("alpha", policy: policy), fakeConfig("beta")])
        defer { Task { await harness.router.stopAll() } }

        let list = await post(harness.router, rpc(1, "tools/list"))
        #expect(names(await list.json, "tools") == ["beta__echo"])
        let perServer = await post(harness.router, rpc(2, "tools/list"), path: "/mcp/alpha")
        #expect(names(await perServer.json, "tools") == [])

        let call = await post(harness.router, callTool(id: 3, "echo"), path: "/mcp/alpha")
        #expect(await call.json?["result"]?["isError"] == .bool(true))
        #expect(harness.asked.value.isEmpty)
    }

    @Test func policyChangesApplyWithoutARestart() async {
        let harness = await PolicyHarness([fakeConfig("alpha", policy: ToolPolicy(defaultPermission: .askAll))])
        defer { Task { await harness.router.stopAll() } }
        _ = await post(harness.router, callTool(id: 1, "echo"), path: "/mcp/alpha")
        #expect(harness.asked.value.count == 1)

        await harness.router.apply([fakeConfig("alpha", policy: ToolPolicy(defaultPermission: .allowAll))])
        let stats = await post(harness.router, callTool(id: 2, "stats"), path: "/mcp/alpha")
        // Same process (initialized once), and no new question.
        #expect(toolText(await stats.json)?["initialize_count"] == .int(1))
        #expect(harness.asked.value.count == 1)
    }

    @Test func recordsActivity() async {
        let harness = await PolicyHarness([fakeConfig("alpha", policy: askForChanges)])
        defer { Task { await harness.router.stopAll() } }
        _ = await postAs("Claude", harness.router, rpc(1, "tools/list"))
        _ = await postAs("Claude", harness.router, callTool(id: 2, "alpha__echo"))
        _ = await postAs("ChatGPT", harness.router, callTool(id: 3, "stats"), path: "/mcp/alpha")

        let events = harness.activity.value
        #expect(events.map(\.method) == ["tools/list", "tools/call", "tools/call"])
        #expect(events.map(\.client.name) == ["Claude", "Claude", "ChatGPT"])
        #expect(events[1].server == "alpha")
        #expect(events[1].tool == "echo")
        #expect(events[1].outcome == .ok)
        #expect(events[2].tool == "stats")
        guard case .denied = events[2].outcome else {
            Issue.record("expected denied, got \(events[2].outcome)")
            return
        }
    }

    @Test func unlistedNamesOnTheCombinedEndpointAreRejectedWithoutAsking() async {
        let harness = await PolicyHarness([fakeConfig("alpha", policy: askForChanges)])
        defer { Task { await harness.router.stopAll() } }
        let call = await post(harness.router, callTool(id: 1, "alpha__stats"))
        #expect(await call.json?["error"]?["code"] == .int(-32602))
        #expect(harness.asked.value.isEmpty)
    }

    @Test func defaultPermissions() {
        let policy = ToolPolicy(defaultPermission: .askForChanges, overrides: ["write": .allow, "wipe": .deny])
        #expect(policy.permission(for: "read", readOnly: true) == .allow)
        #expect(policy.permission(for: "other", readOnly: false) == .ask)
        #expect(policy.permission(for: "write", readOnly: false) == .allow)
        #expect(policy.permission(for: "wipe", readOnly: true) == .deny)
        #expect(ToolPolicy(defaultPermission: .askAll).permission(for: "read", readOnly: true) == .ask)
    }
}
