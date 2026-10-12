import Foundation
import Testing
@testable import PorchlightCore

/// Every server combined, at `/mcp`.
@Suite struct AggregatorTests {
    @Test func initializesAsPorchlight() async {
        await withRouter([fakeConfig("alpha")]) { h in
            let response = await h.post(initialize)
            #expect(await response.json?["result"]?["serverInfo"]?["name"] == .string("porchlight"))
            #expect(await response.json?["result"]?["protocolVersion"] == .string("2025-06-18"))
            #expect(await response.json?["result"]?["capabilities"]?["tools"] != nil)
        }
    }

    @Test func combinesAndRoutesTools() async {
        await withRouter([fakeConfig("alpha"), fakeConfig("beta")]) { h in
            let list = await h.post(rpc(1, "tools/list"))
            #expect(names(await list.json, "tools") == ["alpha__echo", "beta__echo"])
            guard case .array(let tools)? = await list.json?["result"]?["tools"] else {
                Issue.record("no tools")
                return
            }
            #expect(tools.first?["title"] == .string("echo"))

            let call = await h.post(callTool(id: 2, "beta__echo", #"{"x":1}"#))
            #expect(await call.json?["id"] == .int(2))
            #expect(toolText(await call.json)?["server"] == .string("beta"))
            #expect(toolText(await call.json)?["args"]?["x"] == .int(1))
        }
    }

    @Test func routesCallsWithoutAPriorList() async {
        await withRouter([fakeConfig("alpha"), fakeConfig("beta")]) { h in
            let call = await h.post(callTool(id: 3, "alpha__echo"))
            #expect(toolText(await call.json)?["server"] == .string("alpha"))

            let unknown = await h.post(callTool(id: 4, "gamma__echo"))
            #expect(await unknown.json?["error"]?["code"] == .int(-32602))
        }
    }

    @Test func combinesPromptsAndResources() async {
        await withRouter([fakeConfig("alpha"), fakeConfig("beta")]) { h in
            let prompts = await h.post(rpc(1, "prompts/list"))
            #expect(names(await prompts.json, "prompts") == ["alpha__greet", "beta__greet"])
            let prompt = await h.post(rpc(2, "prompts/get", #"{"name":"beta__greet"}"#))
            guard case .array(let messages)? = await prompt.json?["result"]?["messages"] else {
                Issue.record("no messages")
                return
            }
            #expect(messages.first?["content"]?["text"] == .string("hello from beta"))

            let resources = await h.post(rpc(3, "resources/list"))
            #expect(names(await resources.json, "resources") == ["readme", "readme"])
            let read = await h.post(rpc(4, "resources/read", #"{"uri":"fake://beta/readme"}"#))
            guard case .array(let contents)? = await read.json?["result"]?["contents"] else {
                Issue.record("no contents")
                return
            }
            #expect(contents.first?["text"] == .string("beta"))
        }
    }

    @Test func skipsServersThatFailToStart() async {
        let broken = ServerConfig(name: "broken", command: "/nonexistent/server")
        await withRouter([broken, fakeConfig("alpha")]) { h in
            let list = await h.post(rpc(1, "tools/list"))
            #expect(names(await list.json, "tools") == ["alpha__echo"])
        }
    }

    @Test func appliesConfigChangesLive() async {
        await withRouter([fakeConfig("alpha"), fakeConfig("beta")]) { h in
            #expect(await h.post(initialize, path: "/mcp/beta").status == 200)

            await h.router.apply([fakeConfig("alpha"), fakeConfig("beta", enabled: false)])
            #expect(await h.post(initialize, path: "/mcp/beta").status == 404)
            let list = await h.post(rpc(1, "tools/list"))
            #expect(names(await list.json, "tools") == ["alpha__echo"])
        }
    }

    @Test func aliasesFitClientNameRules() {
        #expect(Aggregator.alias(server: "files", name: "read_file") == "files__read_file")
        let dotted = Aggregator.alias(server: "files", name: "read.file")
        #expect(dotted.hasPrefix("files__read_file_"))
        #expect(dotted != Aggregator.alias(server: "files", name: "read_file"))
        let long = Aggregator.alias(server: "server", name: String(repeating: "x", count: 80))
        #expect(long.count == 64)
        #expect(long != Aggregator.alias(server: "server", name: String(repeating: "x", count: 81)))
        #expect(long.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
    }
}
