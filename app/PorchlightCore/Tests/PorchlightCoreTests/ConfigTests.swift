import Foundation
import Testing
@testable import PorchlightCore

/// Server settings, the server list file, and importing from other apps.
@Suite struct ConfigTests {
    @Test func namesAndSlugs() {
        #expect(ServerConfig.isValidName("github"))
        #expect(ServerConfig.isValidName("my-server-2"))
        #expect(!ServerConfig.isValidName("My Server"))
        #expect(!ServerConfig.isValidName("a__b"))
        #expect(!ServerConfig.isValidName("-x"))
        #expect(ServerConfig.slug("My GitHub (work)") == "my-github-work")
        #expect(ServerConfig.slug("___") == "server")
        #expect(ServerConfig.uniqueName("files", taken: ["files", "files-2"]) == "files-3")
    }

    @Test func suggestsNamesFromCommands() {
        let suggest = { ServerConfig.suggestedName(for: splitCommandLine($0)) }
        #expect(suggest("npx -y @modelcontextprotocol/server-filesystem ~/Docs") == "filesystem")
        #expect(suggest("uvx mcp-server-git --repository /tmp/x") == "git")
        #expect(suggest("npx @playwright/mcp@latest") == "playwright")
        #expect(suggest("docker run -i --rm ghcr.io/github/github-mcp-server") == "github")
        #expect(suggest("/usr/local/bin/my-tool-mcp") == "my-tool")
        #expect(suggest("") == "")
    }

    @Test func commandLineRoundTrips() {
        #expect(ServerConfig(name: "new", command: "").commandLineString == "")
        var config = ServerConfig(name: "fs", command: "npx", args: ["-y", "@scope/server", "/Users/me/My Docs"])
        #expect(config.commandLineString == "npx -y @scope/server '/Users/me/My Docs'")
        config.commandLineString = "uvx mcp-server-git --repository \"/tmp/a b\""
        #expect(config.command == "uvx")
        #expect(config.args == ["mcp-server-git", "--repository", "/tmp/a b"])
    }

    @Test func storeRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "porchlight-\(UUID())/servers.json")
        let store = ServerStore(url: url)
        #expect(try store.load() == nil)
        let servers = [ServerConfig(name: "a", command: "x", env: ["TOKEN": "secret"])]
        try store.save(servers)
        #expect(try store.load() == servers)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        // A list that can't be read is an error, not "no list" (which would be overwritten).
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try store.load() }
    }

    @Test func decodesHandWrittenServerLists() throws {
        let written = #"[{"id":"00000000-0000-0000-0000-000000000001","name":"fs","command":"npx","args":["x"],"toolPolicy":{"overrides":{"rm":"deny"}}}]"#
        let server = try #require(try JSONDecoder().decode([ServerConfig].self, from: Data(written.utf8)).first)
        #expect(server.transport == .stdio)
        #expect(server.commandLine == ["npx", "x"])
        #expect(server.enabled)
        #expect(server.toolPolicy.defaultPermission == .askForChanges)
        #expect(server.toolPolicy.overrides == ["rm": .deny])
    }

    @Test func importsFromOtherApps() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "porchlight-home-\(UUID())")
        let write = { (path: String, text: String) in try writeFile(path, text, in: home) }
        try write("Library/Application Support/Claude/claude_desktop_config.json", #"""
            {"mcpServers": {"Git Hub": {"command": "npx", "args": ["-y", "gh-mcp"], "env": {"TOKEN": "t"}}}}
            """#)
        try write(".claude.json", #"""
            {"mcpServers": {"remote": {"type": "http", "url": "https://example.com/mcp"}},
             "projects": {"/code/app": {"mcpServers": {"db": {"type": "stdio", "command": "uvx", "args": ["db-mcp"]}}}}}
            """#)
        try write(".cursor/mcp.json", #"{"mcpServers": {"fs": {"command": "fs-mcp"}}}"#)

        let found = ConfigImporter.candidates(home: home)
        #expect(found.map(\.originalName) == ["Git Hub", "remote", "db", "fs"])

        let github = try #require(found.first?.config)
        #expect(github.name == "git-hub")
        #expect(github.commandLine == ["npx", "-y", "gh-mcp"])
        #expect(github.env == ["TOKEN": "t"])

        #expect(found[1].config == nil)
        #expect(found[1].unsupportedReason == "Remote server: cloud agents can reach it directly")
        #expect(found[2].source == .claudeCode)
        #expect(found[2].scope == "/code/app")
        #expect(found[3].source == .cursor)
    }

    @Test func importsClaudeDesktopExtensions() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "porchlight-home-\(UUID())")
        let claude = "Library/Application Support/Claude"
        let write = { (path: String, text: String) in try writeFile(path, text, in: home) }
        try write("\(claude)/Claude Extensions/local.mcpb.acme.notes/manifest.json", #"""
            {"name": "notes-server", "display_name": "Notes",
             "server": {"type": "node", "mcp_config": {
               "command": "node", "args": ["${__dirname}/server/index.js", "${user_config.folders}", "--limit=${user_config.limit}"],
               "env": {"HELPER": "${__dirname}/bin/helper", "ROOT": "${user_config.root}"},
               "platform_overrides": {"darwin": {"env": {"HELPER": "${__dirname}/bin/helper-mac", "ROOT": "${user_config.root}"}}}}},
             "user_config": {"root": {"type": "directory", "default": "${HOME}/Documents"},
                             "limit": {"type": "number", "default": 10},
                             "folders": {"type": "directory", "multiple": true}}}
            """#)
        try write("\(claude)/Claude Extensions/local.mcpb.acme.notes/server/index.js", "// server")
        try write("\(claude)/Claude Extensions Settings/local.mcpb.acme.notes.json", #"""
            {"isEnabled": true, "userConfig": {"folders": ["/a", "/b"], "limit": 5}}
            """#)
        try write("\(claude)/Claude Extensions/local.mcpb.acme.mail/manifest.json", #"""
            {"name": "mail", "display_name": "Mail",
             "server": {"type": "binary", "mcp_config": {"command": "${__dirname}/mail", "env": {"KEY": "${user_config.api_key}"}}},
             "user_config": {"api_key": {"type": "string", "title": "API Key", "sensitive": true, "required": true}}}
            """#)

        let found = ConfigImporter.candidates(home: home)
        #expect(found.map(\.originalName) == ["Mail", "Notes"])
        #expect(found[0].config == nil)
        #expect(found[0].unsupportedReason?.contains("API Key") == true)

        let notes = try #require(found[1].config)
        let copy = home.appending(path: "Library/Application Support/Porchlight/Extensions/local.mcpb.acme.notes").path
        #expect(found[1].source == .claudeExtensions)
        #expect(notes.name == "notes-server")
        #expect(notes.commandLine == ["node", "\(copy)/server/index.js", "/a", "/b", "--limit=5"])
        #expect(notes.env == ["HELPER": "\(copy)/bin/helper-mac", "ROOT": "\(home.path)/Documents"])

        try ConfigImporter.install(found[1])
        #expect(FileManager.default.fileExists(atPath: "\(copy)/server/index.js"))
        try ConfigImporter.install(found[1])  // a second import replaces the copy
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
        #expect(byName["notion"]?.unsupportedReason == "Remote server: cloud agents can reach it directly")
        #expect(byName["legacy"]?.config == nil)
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
        #expect(ServerConfig.isValidHeaderName("X-Api-Key"))
        #expect(!ServerConfig.isValidHeaderName("Authorization: Bearer x"))
    }
}

/// Writes `text` to `path` under `home`, making folders as needed.
private func writeFile(_ path: String, _ text: String, in home: URL) throws {
    let url = home.appending(path: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}
