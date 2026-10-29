import Foundation
import Testing
@testable import PorchlightCore

@Suite struct LoanTests {
    let guest = ClientIdentity(id: "claude", name: "Claude", loanID: "family")
    let loan = Loan(id: "family", borrower: "Sam", servers: ["beta"], expiresAt: Date().addingTimeInterval(3600), allowedTools: ["beta": ["echo"]])

    @Test func separatesPeopleUsingTheSameApp() async {
        await withRouter([fakeConfig("alpha"), fakeConfig("beta")]) { h in
            await h.router.setLoans([loan])
            await h.post(rpc(0, "resources/list"), from: .claude)
            #expect(names(await h.post(rpc(1, "tools/list"), from: .claude).json, "tools") == ["alpha__echo", "beta__echo"])
            #expect(names(await h.post(rpc(2, "tools/list"), from: guest).json, "tools") == ["beta__echo"])
            #expect(names(await h.post(rpc(3, "prompts/list"), from: guest).json, "prompts") == [])
            let resources = await h.post(rpc(4, "resources/list"), from: guest).json
            if case .array(let items)? = resources?["result"]?["resources"] {
                #expect(items.compactMap { $0["uri"]?.stringValue } == [])
            } else { Issue.record("Missing resources") }
            #expect(await h.post(rpc(5, "tools/list"), path: "/mcp/alpha", from: guest).status == 403)
            #expect(await h.post(callTool(id: 6, "alpha__echo"), from: guest).json?["error"] != nil)
            #expect(await h.post(rpc(7, "resources/read", #"{"uri":"fake://alpha/readme"}"#), from: guest).json?["error"] != nil)
            #expect(toolText(await h.post(callTool(id: 8, "beta__echo"), from: guest).json)?["server"] == .string("beta"))
            #expect(h.activity.withLock { $0.last?.client.name } == "Sam · Claude")
            await h.router.apply([fakeConfig("alpha"), fakeConfig("beta"), fakeConfig("new")])
            #expect(names(await h.post(rpc(9, "tools/list"), from: guest).json, "tools") == ["beta__echo"])
        }
    }

    @Test func missingExpiredAndRevokedLoansFailClosed() async {
        await withRouter([fakeConfig("beta")]) { h in
            #expect(await h.post(initialize, from: guest).status == 403)
            await h.router.setLoans([Loan(id: loan.id, borrower: loan.borrower, servers: loan.servers, expiresAt: .distantPast)])
            #expect(await h.post(initialize, from: guest).status == 403)
            await h.router.setLoans([loan])
            #expect(await h.post(initialize, from: guest).status == 200)
            await h.router.setLoans([])
            #expect(await h.post(callTool(id: 1, "beta__echo"), from: guest).status == 403)
            #expect(await h.post(initialize, from: .claude).status == 200)
        }
    }

    @Test func toolPermissionsStillApply() async {
        await withRouter([fakeConfig("beta", policy: ToolPolicy(defaultPermission: .askAll))]) { h in
            await h.router.setLoans([loan])
            let result = await h.post(callTool(id: 1, "beta__echo"), from: guest).json
            #expect(result?["result"]?["isError"] == .bool(true))
            #expect(h.asked.withLock { $0.count } == 1)
        }
    }

    @Test(arguments: [true, false]) func losingAccessWhileApprovalIsPendingPreventsExecution(revoke: Bool) async {
        let waiting = Locked(false)
        let release = Locked(false)
        let router = Router(environment: ProcessInfo.processInfo.environment, log: { _, _ in }, approve: { _ in
            waiting.withLock { $0 = true }
            while !release.withLock({ $0 }) { await Task.yield() }
            return .allowOnce
        })
        await router.apply([fakeConfig("beta", policy: ToolPolicy(defaultPermission: .askAll))])
        await router.setLoans([loan])
        let task = Task { await router.authorize(server: "beta", tool: "echo", arguments: .object([:]), client: guest, queuedAt: nil) }
        while !waiting.withLock({ $0 }) { await Task.yield() }
        await router.setLoans(revoke ? [] : [Loan(id: loan.id, borrower: loan.borrower, servers: loan.servers, expiresAt: loan.expiresAt)])
        release.withLock { $0 = true }
        #expect(await task.value == .denied("This tool is not allowed for this connection, or its loan has expired or been revoked."))
        await router.stopAll()
    }

    @Test func savesAndReloadsWithoutSilentlyReplacingCorruptData() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LoanStore(url: directory.appending(path: "loans.json"))
        #expect(try store.load().isEmpty)
        let exact = Loan(id: "one", borrower: "Sam", servers: ["beta"], expiresAt: Date(timeIntervalSince1970: 2_000_000_000), allowedTools: ["beta": ["echo"]])
        try store.save([exact])
        #expect(try store.load() == [exact])
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try Data("broken".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "broken")
    }

    @Test func nothingIsAllowedByDefaultEvenWhenTheServerAllowsEverything() async {
        await withRouter([queueConfig("beta")]) { h in
            let empty = Loan(id: loan.id, borrower: loan.borrower, servers: loan.servers, expiresAt: loan.expiresAt)
            await h.router.setLoans([empty])
            for path in ["/mcp", "/mcp/beta"] {
                #expect(names(await h.post(rpc(1, "tools/list"), path: path, from: guest).json, "tools").isEmpty)
                let name = path == "/mcp" ? "beta__echo" : "echo"
                #expect(await h.post(callTool(id: 2, name), path: path, from: guest).json?["result"]?["isError"] == .bool(true))
            }
            #expect(h.asked.withLock { $0.isEmpty })
            #expect(names(await h.post(rpc(3, "tools/list"), from: .claude).json, "tools") == ["beta__echo", "beta__add", "beta__remove"])
        }
    }

    @Test func onlySelectedToolsAreVisibleAndCallableForEachConnection() async {
        await withRouter([queueConfig("beta")]) { h in
            let other = ClientIdentity(id: guest.id, name: guest.name, loanID: "another-person")
            let otherLoan = Loan(id: "another-person", borrower: "Alex", servers: ["beta"], expiresAt: .distantFuture,
                                 allowedTools: ["beta": ["add"]])
            await h.router.setLoans([loan, otherLoan])
            #expect(names(await h.post(rpc(1, "tools/list"), from: guest).json, "tools") == ["beta__echo"])
            #expect(names(await h.post(rpc(2, "tools/list"), from: other).json, "tools") == ["beta__add"])
            for path in ["/mcp", "/mcp/beta"] {
                let prefix = path == "/mcp" ? "beta__" : ""
                for name in ["add", "remove", "unlisted"] {
                    let response = await h.post(callTool(id: 3, prefix + name), path: path, from: guest).json
                    #expect(response?["result"]?["isError"] == .bool(true) || response?["error"] != nil)
                }
            }
            #expect(toolText(await h.post(callTool(id: 5, "beta__add"), from: other).json)?["server"] == .string("beta"))
        }
    }

    @Test func toolAccessDoesNotGrantOtherRPCOrResourceAccess() async {
        await withRouter([fakeConfig("beta")]) { h in
            await h.router.setLoans([loan])
            for path in ["/mcp", "/mcp/beta"] {
                for method in ["resources/read", "prompts/get", "custom/write"] {
                    #expect(await h.post(rpc(1, method), path: path, from: guest).json?["error"] != nil)
                }
                let initialized = await h.post(initialize, path: path, from: guest).json
                #expect(initialized?["result"]?["capabilities"] == .object(["tools": .object([:])]))
                let batch = "[" + rpc(1, "resources/read") + "," + callTool(id: 2, path == "/mcp" ? "beta__remove" : "remove") + "]"
                let reply = await h.post(batch, path: path, from: guest).json
                if case .array(let items) = reply {
                    #expect(items.count == 2)
                    #expect(items.allSatisfy { $0["error"] != nil || $0["result"]?["isError"] == .bool(true) })
                } else { Issue.record("Missing batch response") }
            }
        }
    }

    @Test func serverBlocksStillOverrideExplicitLoanSelection() async {
        await withRouter([fakeConfig("beta", policy: ToolPolicy(defaultPermission: .allowAll, overrides: ["echo": .deny]))]) { h in
            await h.router.setLoans([loan])
            #expect(names(await h.post(rpc(1, "tools/list"), from: guest).json, "tools").isEmpty)
            #expect(await h.post(callTool(id: 2, "beta__echo"), from: guest).json?["result"]?["isError"] == .bool(true))
        }
    }

    @Test func olderLoanFilesDoNotImplicitlyAllowTools() throws {
        let json = #"{"id":"old","borrower":"Sam","servers":["beta"],"expiresAt":"2030-01-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Loan.self, from: Data(json.utf8)).allowedTools.isEmpty)
    }

    @Test func notificationsCannotBypassTheToolAllowlist() async {
        let received = Locked(0)
        let inner = NotificationRecorder(received: received)
        let router = Router(environment: [:])
        let borrowed = GatedEndpoint(inner: inner, scope: .server("beta"), client: guest,
                                     allowed: ["beta"], queuedAt: nil, router: router)
        let message: JSONValue = .object(["jsonrpc": .string("2.0"), "method": .string("tools/call"),
                                          "params": .object(["name": .string("remove")])])
        await borrowed.notify(message)
        #expect(received.withLock { $0 } == 0)
        let owner = GatedEndpoint(inner: inner, scope: .server("beta"), client: .claude,
                                  allowed: nil, queuedAt: nil, router: router)
        await owner.notify(message)
        #expect(received.withLock { $0 } == 1)
    }

}


private struct NotificationRecorder: MCPEndpoint {
    let received: Locked<Int>
    func call(_ request: JSONValue, onProgress: ProgressSink?) async -> JSONValue { .rpcResult(id: request.rpcID, .object([:])) }
    func notify(_ notification: JSONValue) async { received.withLock { $0 += 1 } }
}
