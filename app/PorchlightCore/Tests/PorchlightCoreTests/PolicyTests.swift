import Foundation
import Testing
@testable import PorchlightCore

/// Tool permissions: allow, ask, block.
@Suite struct PolicyTests {
    let askForChanges = ToolPolicy(defaultPermission: .askForChanges)

    @Test func readOnlyToolsRunAndOthersAsk() async {
        await withRouter([fakeConfig("alpha", policy: askForChanges)]) { h in
            let echo = await h.post(callTool(id: 1, "alpha__echo"), from: .claude)
            #expect(toolText(await echo.json)?["server"] == .string("alpha"))
            #expect(h.asked.value.isEmpty)

            // `stats` isn't listed (so not marked read-only): it needs approval, and the answer is no.
            let stats = await h.post(callTool(id: 2, "stats"), path: "/mcp/alpha", from: .claude)
            #expect(await stats.json?["id"] == .int(2))
            #expect(await stats.json?.failure?.contains("denied") == true)
            #expect(await stats.json?["result"]?["isError"] == .bool(true))
            let asked = h.asked.value
            #expect(asked.map(\.tool) == ["stats"])
            #expect(asked.first?.server == "alpha")
            #expect(asked.first?.client == .claude)
        }
    }

    @Test func approvedCallsGoThrough() async {
        await withRouter([fakeConfig("alpha", policy: askForChanges)], answer: .allowOnce) { h in
            let stats = await h.post(callTool(id: 1, "stats"), path: "/mcp/alpha")
            #expect(toolText(await stats.json)?["initialize_count"] == .int(1))
            await h.post(callTool(id: 2, "stats"), path: "/mcp/alpha")
            #expect(h.asked.value.count == 2)
        }
    }

    @Test func allowAlwaysStopsAsking() async {
        await withRouter([fakeConfig("alpha", policy: askForChanges)], answer: .allowAlways) { h in
            await h.post(callTool(id: 1, "stats"), path: "/mcp/alpha")
            let again = await h.post(callTool(id: 2, "stats"), path: "/mcp/alpha")
            #expect(toolText(await again.json)?["initialize_count"] == .int(1))
            #expect(h.asked.value.count == 1)
        }
    }

    @Test func blockedToolsAreHiddenAndRefused() async {
        let policy = ToolPolicy(defaultPermission: .allowAll, overrides: ["echo": .deny])
        await withRouter([fakeConfig("alpha", policy: policy), fakeConfig("beta")]) { h in
            let list = await h.post(rpc(1, "tools/list"))
            #expect(names(await list.json, "tools") == ["beta__echo"])
            let perServer = await h.post(rpc(2, "tools/list"), path: "/mcp/alpha")
            #expect(names(await perServer.json, "tools") == [])

            let call = await h.post(callTool(id: 3, "echo"), path: "/mcp/alpha")
            #expect(await call.json?["result"]?["isError"] == .bool(true))
            #expect(h.asked.value.isEmpty)
        }
    }

    @Test func policyChangesApplyWithoutARestart() async {
        await withRouter([fakeConfig("alpha", policy: ToolPolicy(defaultPermission: .askAll))]) { h in
            await h.post(callTool(id: 1, "echo"), path: "/mcp/alpha")
            #expect(h.asked.value.count == 1)

            await h.router.apply([fakeConfig("alpha", policy: ToolPolicy(defaultPermission: .allowAll))])
            let stats = await h.post(callTool(id: 2, "stats"), path: "/mcp/alpha")
            // Same process (initialized once), and no new question.
            #expect(toolText(await stats.json)?["initialize_count"] == .int(1))
            #expect(h.asked.value.count == 1)
        }
    }

    @Test func recordsActivity() async {
        await withRouter([fakeConfig("alpha", policy: askForChanges)]) { h in
            await h.post(rpc(1, "tools/list"), from: .claude)
            await h.post(callTool(id: 2, "alpha__echo"), from: .claude)
            await h.post(callTool(id: 3, "stats"), path: "/mcp/alpha", from: .chatgpt)

            let events = h.activity.value
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
    }

    @Test func unlistedNamesOnTheCombinedEndpointAreRejectedWithoutAsking() async {
        await withRouter([fakeConfig("alpha", policy: askForChanges)]) { h in
            let call = await h.post(callTool(id: 1, "alpha__stats"))
            #expect(await call.json?["error"]?["code"] == .int(-32602))
            #expect(h.asked.value.isEmpty)
        }
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
