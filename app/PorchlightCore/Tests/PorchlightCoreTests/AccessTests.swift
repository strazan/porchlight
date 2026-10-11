import Foundation
import Testing
@testable import PorchlightCore

/// A request from a paired app, as the relay forwards it.
func postFrom(_ clientID: String, _ router: Router, _ body: String, path: String = "/mcp") async -> RecordedResponse {
    let recorded = RecordedResponse()
    let request = HTTPRequest(
        id: UUID().uuidString, method: "POST", path: path,
        headers: [
            ("accept", "application/json"),
            ("porchlight-client-id", clientID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!),
            ("porchlight-client-name", "App"),
        ],
        body: Data(body.utf8)
    )
    await router.handle(request, recorded.responder)
    return recorded
}

@Suite struct AccessTests {
    func router() async -> Router {
        let router = await makeRouter([fakeConfig("alpha"), fakeConfig("beta")])
        await router.setClientAccess(["chatgpt": ["beta"]])
        return router
    }

    @Test func limitedAppsOnlySeeTheirServers() async {
        let router = await router()
        defer { Task { await router.stopAll() } }

        let tools = await postFrom("chatgpt", router, rpc(1, "tools/list"))
        #expect(names(await tools.json, "tools") == ["beta__echo"])
        let prompts = await postFrom("chatgpt", router, rpc(2, "prompts/list"))
        #expect(names(await prompts.json, "prompts") == ["beta__greet"])
        let resources = await postFrom("chatgpt", router, rpc(3, "resources/list"))
        guard case .array(let listed)? = await resources.json?["result"]?["resources"] else {
            Issue.record("no resources")
            return
        }
        #expect(listed.compactMap { $0["uri"]?.stringValue } == ["fake://beta/readme"])
        let initialized = await postFrom("chatgpt", router, initialize)
        let instructions = await initialized.json?["result"]?["instructions"]?.stringValue ?? ""
        #expect(instructions.contains("- beta"))
        #expect(!instructions.contains("alpha"))
    }

    @Test func limitedAppsCantReachOtherServers() async {
        let router = await router()
        defer { Task { await router.stopAll() } }
        // Another app lists everything first, so the routes exist.
        _ = await postFrom("claude", router, rpc(1, "tools/list"))
        _ = await postFrom("claude", router, rpc(2, "resources/list"))

        let call = await postFrom("chatgpt", router, callTool(id: 3, "alpha__echo"))
        #expect(await call.json?["error"]?["code"] == .int(-32602))
        let prompt = await postFrom("chatgpt", router, rpc(4, "prompts/get", #"{"name":"alpha__greet"}"#))
        #expect(await prompt.json?["error"] != nil)
        let read = await postFrom("chatgpt", router, rpc(5, "resources/read", #"{"uri":"fake://alpha/readme"}"#))
        #expect(await read.json?["error"]?["code"] == .int(-32002))

        let perServer = await postFrom("chatgpt", router, rpc(6, "tools/list"), path: "/mcp/alpha")
        #expect(await perServer.status == 403)
        let allowed = await postFrom("chatgpt", router, rpc(7, "tools/list"), path: "/mcp/beta")
        #expect(names(await allowed.json, "tools") == ["echo"])

        // The other app's view is unaffected.
        let other = await postFrom("claude", router, callTool(id: 8, "alpha__echo"))
        #expect(toolText(await other.json)?["server"] == .string("alpha"))
    }

    @Test func appsWithoutASettingSeeEverything() async {
        let router = await router()
        defer { Task { await router.stopAll() } }
        let tools = await postFrom("claude", router, rpc(1, "tools/list"))
        #expect(names(await tools.json, "tools") == ["alpha__echo", "beta__echo"])
        // No identity (not via the relay's OAuth): no limit either.
        let anonymous = await post(router, rpc(2, "tools/list"))
        #expect(names(await anonymous.json, "tools") == ["alpha__echo", "beta__echo"])
    }
}

@Suite struct ManyToolsTests {
    @Test func instructionsSayWhatEachServerIsFor() async {
        var notes = fakeConfig("notes")
        notes.env["FAKE_INSTRUCTIONS"] = "Reads and writes the notes in the user's vault.\n\nUse search before get_note."
        let router = await makeRouter([notes, fakeConfig("plain")])
        defer { Task { await router.stopAll() } }
        _ = await post(router, rpc(1, "tools/list")) // connects both servers

        let initialized = await post(router, initialize)
        let instructions = await initialized.json?["result"]?["instructions"]?.stringValue ?? ""
        #expect(instructions.contains("- notes: Reads and writes the notes in the user's vault."))
        #expect(!instructions.contains("get_note"))
        #expect(instructions.contains("- plain"))
    }

    @Test func summariesAreOneShortLine() {
        let long = JSONValue.object(["instructions": .string(String(repeating: "word ", count: 80))])
        #expect(Aggregator.summary(of: long)?.count == 200)
        let titled = JSONValue.object(["serverInfo": .object(["name": .string("x"), "title": .string("Obsidian  Notes")])])
        #expect(Aggregator.summary(of: titled) == "Obsidian Notes")
        #expect(Aggregator.summary(of: .object(["instructions": .string("  ")])) == nil)
        #expect(Aggregator.summary(of: nil) == nil)
    }

    @Test func countsWhatEachAppSees() async {
        var blocking = ToolPolicy(defaultPermission: .allowAll)
        blocking.overrides["remove"] = .deny
        let router = await makeRouter([queueConfig("alpha"), queueConfig("beta", policy: blocking)])
        defer { Task { await router.stopAll() } }
        await router.setClientAccess(["chatgpt": ["beta"]])
        #expect(await router.toolCount(for: "") == 5)
        #expect(await router.toolCount(for: "chatgpt") == 2)
    }
}
