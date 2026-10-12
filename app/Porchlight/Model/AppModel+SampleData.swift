#if DEBUG
import Foundation
import PorchlightCore

// Sample data, for rendering every screen in snapshots (see Snapshots.swift).
extension AppModel {
    enum SampleScenario {
        /// Connected, with servers, apps and activity.
        case everything
        /// Nothing set up yet.
        case firstRun
        /// A relay, but no servers yet.
        case noServers
        case waitingForToolApproval
        case waitingForPairing
        /// Set up, but turned off.
        case switchedOff
    }

    func loadSampleData(_ scenario: SampleScenario) {
        precondition(isSampleMode, "sample data is only for snapshots")
        guard scenario != .firstRun else { return }
        relayURL = "https://porchlight-relay.you.workers.dev"
        secret = "sample-secret"
        state = .relay(.connected)
        deployment = Deployment(accountID: "a1", accountName: "Personal", scriptName: "porchlight-relay", relaySHA: bundledRelay?.sha256 ?? "")

        var obsidian = ServerConfig(name: "obsidian", url: "http://127.0.0.1:27123/mcp/", headers: ["Authorization": "Bearer 0123456789abcdef"])
        obsidian.toolPolicy.overrides = ["search": .allow, "delete_note": .deny]
        servers = [
            obsidian,
            ServerConfig(name: "filesystem", command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/Users/you/Documents"]),
            ServerConfig(name: "home-assistant", url: "http://homeassistant.local:8123/api/mcp", headers: ["Authorization": "Bearer 0123456789abcdef"]),
            ServerConfig(
                name: "apple-reminders", command: "node",
                args: ["/Users/you/Library/Application Support/Porchlight/Extensions/local.mcpb.example.apple-reminders/server/index.js"],
                env: ["REMINDERS_BINARY": "/Users/you/Library/Application Support/Porchlight/Extensions/local.mcpb.example.apple-reminders/bin/reminders-eventkit"]
            ),
            ServerConfig(name: "playwright", command: "npx", args: ["@playwright/mcp@latest"], enabled: false),
        ]
        serverStatus = ["obsidian": .running, "filesystem": .running, "home-assistant": .running, "apple-reminders": .running]

        let now = Date()
        clients = [
            PairedClient(id: "g1", clientID: "https://claude.ai/oauth/mcp-oauth-client-metadata", clientName: "Claude", clientDomain: "claude.ai", createdAt: now.addingTimeInterval(-3 * 86400)),
            PairedClient(id: "g2", clientID: "dcr-7f3a", clientName: "ChatGPT", clientDomain: nil, createdAt: now.addingTimeInterval(-2 * 3600)),
        ]
        clientAccess = ["dcr-7f3a": ["obsidian"]]
        // As a real pairing would: where its access went is where its icon comes from.
        icons.learnWebsite("chatgpt.com", for: IconStore.key(app: "dcr-7f3a"))

        let claude = ClientIdentity(id: "https://claude.ai/oauth/mcp-oauth-client-metadata", name: "Claude")
        let chatgpt = ClientIdentity(id: "dcr-7f3a", name: "ChatGPT")
        activity = [
            ActivityEvent(date: now.addingTimeInterval(-600), client: claude, server: nil, method: "tools/list", tool: nil, duration: .milliseconds(184), outcome: .ok),
            ActivityEvent(date: now.addingTimeInterval(-540), client: claude, server: "obsidian", method: "tools/call", tool: "search", duration: .milliseconds(92), outcome: .ok),
            ActivityEvent(date: now.addingTimeInterval(-500), client: claude, server: "filesystem", method: "tools/call", tool: "read_text_file", duration: .milliseconds(31), outcome: .ok),
            ActivityEvent(date: now.addingTimeInterval(-420), client: claude, server: "filesystem", method: "tools/call", tool: "write_file", duration: .seconds(6), outcome: .denied("The user denied this call to write_file on their Mac.")),
            ActivityEvent(date: now.addingTimeInterval(-300), client: chatgpt, server: "obsidian", method: "tools/call", tool: "get_note", duration: .milliseconds(140), outcome: .ok),
            ActivityEvent(date: now.addingTimeInterval(-240), client: claude, server: "apple-reminders", method: "tools/call", tool: "get_today", duration: .milliseconds(48), outcome: .ok),
            ActivityEvent(date: now.addingTimeInterval(-120), client: claude, server: "home-assistant", method: "tools/call", tool: "GetLiveContext", duration: .seconds(15), outcome: .error("home-assistant didn't answer in time")),
        ]
        for (index, line) in [
            (nil, "Connecting to https://porchlight-relay.you.workers.dev"),
            (nil, "Relay connected"),
            ("obsidian", "connected to http://127.0.0.1:27123/mcp/"),
            ("filesystem", "started: npx -y @modelcontextprotocol/server-filesystem /Users/you/Documents"),
            ("filesystem", "Secure MCP Filesystem Server running on stdio"),
            ("home-assistant", "connected to http://homeassistant.local:8123/api/mcp"),
            ("apple-reminders", "started: node …/apple-reminders/server/index.js"),
        ].enumerated() {
            logs.append(LogLine(id: index, date: now.addingTimeInterval(Double(index - 20)), server: line.0, text: line.1))
        }

        let reads = { (title: String) in ToolHints(readOnly: true, destructive: false, declaresDestructive: false, title: title) }
        sampleProbe = .success(ServerProbe.Report(serverName: "obsidian-local-rest-api", tools: [
            .init(name: "search", description: "Full-text search across the vault.", hints: reads("Search notes")),
            .init(name: "get_note", description: nil, hints: reads("Read a note")),
            .init(
                name: "append_to_note", description: "Adds text to the end of a note.",
                hints: ToolHints(readOnly: false, destructive: false, declaresDestructive: false, title: "Append to a note")
            ),
            .init(
                name: "delete_note", description: "Moves a note to the trash.",
                hints: ToolHints(readOnly: false, destructive: true, declaresDestructive: true, title: "Delete a note")
            ),
        ]))
        sampleImportCandidates = [
            ImportCandidate(source: .claudeDesktop, scope: nil, originalName: "filesystem", config: servers[1], unsupportedReason: nil),
            ImportCandidate(source: .claudeDesktop, scope: nil, originalName: "memory", config: ServerConfig(name: "memory", command: "npx", args: ["-y", "@modelcontextprotocol/server-memory"]), unsupportedReason: nil),
            ImportCandidate(source: .claudeExtensions, scope: nil, originalName: "Apple Reminders", config: ServerConfig(name: "apple-reminders", command: "node", args: ["/Users/you/Library/Application Support/Porchlight/Extensions/apple-reminders/server/index.js"]), unsupportedReason: nil, bundle: ExtensionBundle(source: URL(filePath: "/"), destination: URL(filePath: "/"))),
            ImportCandidate(source: .claudeCode, scope: nil, originalName: "linear", config: nil, unsupportedReason: "Remote server: cloud agents can reach it directly"),
            ImportCandidate(source: .claudeCode, scope: "/Users/you/code/porchlight", originalName: "sqlite", config: ServerConfig(name: "sqlite", command: "uvx", args: ["mcp-server-sqlite", "--db-path", "dev.db"]), unsupportedReason: nil),
            ImportCandidate(source: .cursor, scope: nil, originalName: "obsidian", config: obsidian, unsupportedReason: nil),
        ]

        switch scenario {
        case .noServers:
            servers = []
            serverStatus = [:]
            clients = []
            activity = []
        case .waitingForToolApproval:
            prompts.showSample(ToolApprovalRequest(
                client: claude, server: "apple-reminders", tool: "create_reminder", title: "Create reminder",
                arguments: .object(["list": .string("Groceries"), "title": .string("Oat milk"), "dueDate": .string("2026-10-12T09:00:00")])
            ))
        case .switchedOff:
            state = .off
            serverStatus = [:]
        case .waitingForPairing:
            prompts.add(PairingRequest(
                id: "p1", code: "482913", clientID: "https://chatgpt.com/oauth/client", clientName: "ChatGPT",
                clientDomain: "chatgpt.com", redirectHost: "chatgpt.com", loopback: false
            ))
        default:
            break
        }
    }
}
#endif
