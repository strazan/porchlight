import Foundation
import Testing
@testable import PorchlightCore

/// Which servers each app may use.
@Suite struct AccessTests {
    let servers = [fakeConfig("alpha"), fakeConfig("beta")]
    let access: [String: Set<String>] = ["chatgpt": ["beta"]]

    @Test func limitedAppsOnlySeeTheirServers() async {
        await withRouter(servers, access: access) { h in
            let tools = await h.post(rpc(1, "tools/list"), from: .chatgpt)
            #expect(names(await tools.json, "tools") == ["beta__echo"])
            let prompts = await h.post(rpc(2, "prompts/list"), from: .chatgpt)
            #expect(names(await prompts.json, "prompts") == ["beta__greet"])
            let resources = await h.post(rpc(3, "resources/list"), from: .chatgpt)
            guard case .array(let listed)? = await resources.json?["result"]?["resources"] else {
                Issue.record("no resources")
                return
            }
            #expect(listed.compactMap { $0["uri"]?.stringValue } == ["fake://beta/readme"])
            let initialized = await h.post(initialize, from: .chatgpt)
            let instructions = await initialized.json?["result"]?["instructions"]?.stringValue ?? ""
            #expect(instructions.contains("- beta"))
            #expect(!instructions.contains("alpha"))
        }
    }

    @Test func limitedAppsCantReachOtherServers() async {
        await withRouter(servers, access: access) { h in
            // Another app lists everything first, so the routes exist.
            await h.post(rpc(1, "tools/list"), from: .claude)
            await h.post(rpc(2, "resources/list"), from: .claude)

            let call = await h.post(callTool(id: 3, "alpha__echo"), from: .chatgpt)
            #expect(await call.json?["error"]?["code"] == .int(-32602))
            let prompt = await h.post(rpc(4, "prompts/get", #"{"name":"alpha__greet"}"#), from: .chatgpt)
            #expect(await prompt.json?["error"] != nil)
            let read = await h.post(rpc(5, "resources/read", #"{"uri":"fake://alpha/readme"}"#), from: .chatgpt)
            #expect(await read.json?["error"]?["code"] == .int(-32002))

            let perServer = await h.post(rpc(6, "tools/list"), path: "/mcp/alpha", from: .chatgpt)
            #expect(await perServer.status == 403)
            let allowed = await h.post(rpc(7, "tools/list"), path: "/mcp/beta", from: .chatgpt)
            #expect(names(await allowed.json, "tools") == ["echo"])

            // The other app's view is unaffected.
            let other = await h.post(callTool(id: 8, "alpha__echo"), from: .claude)
            #expect(toolText(await other.json)?["server"] == .string("alpha"))
        }
    }

    @Test func appsWithoutASettingSeeEverything() async {
        await withRouter(servers, access: access) { h in
            let tools = await h.post(rpc(1, "tools/list"), from: .claude)
            #expect(names(await tools.json, "tools") == ["alpha__echo", "beta__echo"])
            // No identity (not through the relay's OAuth): no limit either.
            let anonymous = await h.post(rpc(2, "tools/list"))
            #expect(names(await anonymous.json, "tools") == ["alpha__echo", "beta__echo"])
        }
    }

    @Test func appsWithNoServersSeeNothing() async {
        await withRouter(servers, access: ["claude": []]) { h in
            let tools = await h.post(rpc(1, "tools/list"), from: .claude)
            #expect(names(await tools.json, "tools") == [])
            let call = await h.post(callTool(id: 2, "alpha__echo"), from: .claude)
            #expect(await call.json?["error"] != nil)
        }
    }
}
