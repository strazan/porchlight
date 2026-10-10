import Foundation
import Testing
@testable import PorchlightCore

/// Runs `fake_http_server.py` and yields its /mcp URL.
final class FakeHTTPServer: @unchecked Sendable {
    let url: URL
    private let process = Process()

    init() throws {
        let script = Bundle.module.path(forResource: "fake_http_server", ofType: "py", inDirectory: "Fixtures")!
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", script]
        process.standardOutput = stdout
        try process.run()
        // The first line is the port it's listening on.
        var line = Data()
        while true {
            let byte = stdout.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty || byte == Data("\n".utf8) { break }
            line.append(byte)
        }
        url = URL(string: "http://127.0.0.1:\(String(decoding: line, as: UTF8.self))/mcp/")!
    }

    deinit { process.terminate() }
}

func httpConfig(_ name: String, url: URL, key: String = "test-key") -> ServerConfig {
    var config = ServerConfig(name: name, url: url.absoluteString, headers: ["Authorization": "Bearer \(key)"])
    config.toolPolicy = ToolPolicy(defaultPermission: .allowAll)
    return config
}

@Suite struct HTTPUpstreamTests {
    @Test func servesAnHTTPServerPerServerAndCombined() async throws {
        let server = try FakeHTTPServer()
        let router = await makeRouter([httpConfig("obsidian", url: server.url), fakeConfig("alpha")])
        defer { Task { await router.stopAll() } }

        let initialized = await post(router, initialize, path: "/mcp/obsidian")
        #expect(await initialized.json?["result"]?["serverInfo"]?["name"] == .string("fake-http"))

        let list = await post(router, rpc(1, "tools/list"))
        #expect(names(await list.json, "tools") == ["obsidian__search", "alpha__echo"])

        let call = await post(router, callTool(id: 2, "obsidian__search", #"{"q":"porch"}"#))
        #expect(await call.json?["id"] == .int(2))
        let echoed = toolText(await call.json)
        #expect(echoed?["args"]?["q"] == .string("porch"))
        // After initialize, requests carry the negotiated protocol version.
        #expect(echoed?["protocol"] == .string("2025-06-18"))
    }

    @Test func forwardsSSEProgress() async throws {
        let server = try FakeHTTPServer()
        let router = await makeRouter([httpConfig("obsidian", url: server.url)])
        defer { Task { await router.stopAll() } }

        let call = rpc(3, "tools/call", #"{"name":"search","arguments":{},"_meta":{"progressToken":"p"}}"#)
        let response = await post(router, call, path: "/mcp/obsidian", accept: "application/json, text/event-stream")
        let messages = sseMessages(await response.text)
        #expect(messages.first?["method"] == .string("notifications/progress"))
        #expect(messages.last?["id"] == .int(3))
        #expect(messages.last?["result"] != nil)
    }

    @Test func reconnectsWhenTheServerForgetsTheSession() async throws {
        let server = try FakeHTTPServer()
        let router = await makeRouter([httpConfig("obsidian", url: server.url)])
        defer { Task { await router.stopAll() } }

        _ = await post(router, callTool(id: 1, "restart"), path: "/mcp/obsidian")
        // The old session is gone; Porchlight initializes again and retries.
        let stats = await post(router, callTool(id: 2, "stats"), path: "/mcp/obsidian")
        #expect(toolText(await stats.json)?["initialize_count"] == .int(2))
    }

    @Test func reportsAuthAndConnectionFailures() async throws {
        let server = try FakeHTTPServer()
        let statuses = Locked<[String: UpstreamStatus]>([:])
        let router = Router(environment: [:], log: { _, _ in }, onStatus: { name, status in
            statuses.withLock { $0[name] = status }
        })
        await router.apply([
            httpConfig("wrongkey", url: server.url, key: "nope"),
            ServerConfig(name: "closed", url: "http://127.0.0.1:9/mcp"),
        ])
        defer { Task { await router.stopAll() } }

        let refused = await post(router, rpc(1, "tools/list"), path: "/mcp/wrongkey")
        let message = await refused.json?["error"]?["message"]?.stringValue ?? ""
        #expect(message.contains("Authorization"))
        let closed = await post(router, rpc(1, "tools/list"), path: "/mcp/closed")
        #expect(await closed.json?["error"] != nil)
        #expect(statuses.value["closed"].map { if case .failed = $0 { true } else { false } } == true)

        // The combined endpoint still answers, without them.
        let list = await post(router, rpc(2, "tools/list"))
        #expect(names(await list.json, "tools") == [])
    }

    @Test func importsLocalHTTPServersOnly() {
        let found = ConfigImporter.parse(.object([
            "obsidian": .object([
                "type": .string("http"), "url": .string("https://127.0.0.1:27124/mcp/"),
                "headers": .object(["Authorization": .string("Bearer k")]),
            ]),
            "notion": .object(["type": .string("http"), "url": .string("https://mcp.notion.com/mcp")]),
            "legacy": .object(["type": .string("sse"), "url": .string("http://localhost:3000/sse")]),
        ]), source: .claudeCode, scope: nil)
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.originalName, $0) })
        #expect(byName["obsidian"]?.config?.transport == .http)
        #expect(byName["obsidian"]?.config?.headers == ["Authorization": "Bearer k"])
        #expect(byName["notion"]?.config == nil)
        #expect(byName["notion"]?.unsupportedReason == "Remote server: add it to your AI app directly")
        #expect(byName["legacy"]?.config == nil)
    }

    @Test func probesAConfigBeforeSaving() async throws {
        let server = try FakeHTTPServer()
        let good = await Router.probe(httpConfig("obsidian", url: server.url), environment: [:])
        guard case .success(let found) = good else {
            Issue.record("expected the probe to succeed, got \(good)")
            return
        }
        #expect(found.serverName == "fake-http")
        #expect(found.tools.map(\.name) == ["search"])
        #expect(found.tools.first?.readOnly == false)

        guard case .failure(let error) = await Router.probe(httpConfig("obsidian", url: server.url, key: "nope"), environment: [:]) else {
            Issue.record("expected the wrong key to fail")
            return
        }
        #expect(error.message.contains("Authorization"))
    }

    @Test func understandsPastedAPIKeys() {
        let key = "8519bbb30d11"
        for pasted in [key, "Bearer \(key)", "Authorization: Bearer \(key)", #""Authorization": "Bearer \#(key)","#, "  \(key)\n"] {
            #expect(ServerConfig.bearerToken(from: pasted) == key, "pasted: \(pasted)")
        }
        var config = ServerConfig(name: "o", url: "http://127.0.0.1:27123/mcp/")
        config.bearerToken = "Authorization: Bearer \(key)"
        #expect(config.headers == ["Authorization": "Bearer \(key)"])
        #expect(config.bearerToken == key)
        config.bearerToken = ""
        #expect(config.headers.isEmpty)
    }

    @Test func repairsAWholeHeaderLineSavedAsTheName() {
        var config = ServerConfig(name: "o", url: "http://127.0.0.1:27123/mcp/")
        config.headers = [#""Authorization": "Bearer abc""#: "", "X-Ok": "1"]
        #expect(config.repairingHeaders().headers == ["Authorization": "Bearer abc", "X-Ok": "1"])
        #expect(ServerConfig.isValidHeaderName("X-Api-Key"))
        #expect(!ServerConfig.isValidHeaderName("Authorization: Bearer x"))
    }

    @Test func decodesServerListsSavedBeforeHTTP() throws {
        let old = #"[{"id":"00000000-0000-0000-0000-000000000001","name":"fs","command":"npx","args":["x"],"env":{},"enabled":true}]"#
        let servers = try JSONDecoder().decode([ServerConfig].self, from: Data(old.utf8))
        #expect(servers.first?.transport == .stdio)
        #expect(servers.first?.commandLine == ["npx", "x"])
        #expect(servers.first?.headers == [:])
    }
}
