import Foundation
import PorchlightCore

let usage = """
    Usage: porchlight-cli --relay <url> [--name <name>] -- <command> [args...]
           porchlight-cli --relay <url> [--config <servers.json>]
           porchlight-cli --check [--config <servers.json>]

    Connects to a Porchlight relay and serves local stdio MCP servers through it: all of
    them combined at <relay>/mcp, and each one at <relay>/mcp/<name>.

      --relay <url>      Relay URL, e.g. https://porchlight-relay.you.workers.dev
      --name <name>      Name for a server given after -- (default: "default")
      --config <file>    Server list to serve (default: the Porchlight app's list)
      --check            Connect to each enabled server, report what answers, and exit
      --allow-tools      Run every tool without asking (default: ask on the terminal for
                         tools that don't declare themselves read-only)
      --queue-key <file> While this host is offline, let the relay save calls to tools
                         that only add something, sealed to the key in <file> (created if
                         missing), and run them when it's back

    The relay's shared secret is read from PORCHLIGHT_SECRET.

    Example:
      PORCHLIGHT_SECRET=… porchlight-cli --relay http://localhost:8787 --name everything \\
        -- npx -y @modelcontextprotocol/server-everything
    """

func fail(_ message: String) -> Never {
    stderrLog("error: \(message)\n\n\(usage)")
    exit(64)
}

var relayArg: String?
var configArg: String?
var checkOnly = false
var allowTools = false
var queueKeyArg: String?
var name = "default"
var command: [String] = []
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--relay":
        guard let value = args.popFirst() else { fail("--relay needs a value") }
        relayArg = value
    case "--name":
        guard let value = args.popFirst() else { fail("--name needs a value") }
        name = value
    case "--config":
        guard let value = args.popFirst() else { fail("--config needs a value") }
        configArg = value
    case "--check": checkOnly = true
    case "--allow-tools": allowTools = true
    case "--queue-key":
        guard let value = args.popFirst() else { fail("--queue-key needs a value") }
        queueKeyArg = value
    case "--": command = Array(args); args.removeAll()
    case "-h", "--help": print(usage); exit(0)
    default: fail("unknown argument \(arg)")
    }
}
@MainActor func loadServers() -> [ServerConfig] {
    if !command.isEmpty { return [ServerConfig(name: name, command: command[0], args: Array(command.dropFirst()))] }
    let store = configArg.map { ServerStore(url: URL(fileURLWithPath: $0)) } ?? .standard
    guard let loaded = store.load(), !loaded.isEmpty else {
        fail("no servers: pass a command after --, or a --config file (looked in \(store.url.path))")
    }
    return loaded.map { $0.repairingHeaders() }
}

if checkOnly {
    var failed = false
    for server in loadServers() where server.enabled {
        switch await Router.probe(server, environment: ProcessInfo.processInfo.environment) {
        case .success(let found): print("✓ \(server.name): \(found.serverName), \(found.toolCount) tools")
        case .failure(let error):
            failed = true
            print("✗ \(server.name): \(error.message)")
        }
    }
    exit(failed ? 1 : 0)
}

guard let relayArg else { fail("--relay is required") }
guard ServerConfig.isValidName(name) else { fail("--name must be lowercase letters, digits and hyphens") }
guard let secret = ProcessInfo.processInfo.environment["PORCHLIGHT_SECRET"], !secret.isEmpty else {
    fail("PORCHLIGHT_SECRET is not set")
}
guard let relayURL = agentURL(from: relayArg) else { fail("invalid relay URL \(relayArg)") }

/// Accepts the relay's public URL and derives its WebSocket endpoint.
func agentURL(from string: String) -> URL? {
    guard var components = URLComponents(string: string) else { return nil }
    switch components.scheme {
    case "https": components.scheme = "wss"
    case "http": components.scheme = "ws"
    case "wss", "ws": break
    default: return nil
    }
    if components.path.isEmpty || components.path == "/" { components.path = "/agent" }
    return components.url
}

var servers = loadServers()
if allowTools {
    for index in servers.indices { servers[index].toolPolicy = ToolPolicy(defaultPermission: .allowAll) }
}

/// One question at a time on the terminal; no terminal (or end of input) means no.
actor TerminalPrompt {
    func ask(_ question: String) async -> String {
        stderrLog(question)
        FileHandle.standardError.write(Data("> ".utf8))
        let answer = await Task.detached { readLine() }.value
        return answer?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    }
}
let prompt = TerminalPrompt()

let routerBox = Locked<Router?>(nil)
let router = Router(
    environment: ProcessInfo.processInfo.environment,
    approve: { request in
        let answer = await prompt.ask("""

            \(request.clientName) wants to run \(request.tool) on \(request.server) with:
            \(String(decoding: request.arguments.serialized(), as: UTF8.self))
            Allow? [y]es / [N]o / [a]lways for this tool
            """)
        switch answer {
        case "a", "always":
            stderrLog("allowing \(request.tool) for the rest of this session")
            await routerBox.value?.setPermission(.allow, tool: request.tool, server: request.server)
            return .allowAlways
        case "y", "yes": return .allowOnce
        default: return .deny
        }
    }
)
routerBox.withLock { $0 = router }
await router.apply(servers)
for server in servers where server.enabled {
    stderrLog("serving \(server.name): \(server.commandLineString)")
}

/// The queue key in `path`, made and saved there (readable only by you) if it's missing.
func loadQueueKey(_ path: String) -> QueueKey {
    let url = URL(fileURLWithPath: path)
    if let saved = try? Data(contentsOf: url), let key = try? QueueKey(rawRepresentation: saved) { return key }
    let key = QueueKey()
    guard FileManager.default.createFile(atPath: url.path, contents: key.rawRepresentation, attributes: [.posixPermissions: 0o600]) else {
        fail("couldn't write the queue key to \(path)")
    }
    return key
}
let queueKey = queueKeyArg.map(loadQueueKey)

let (events, eventSink) = AsyncStream.makeStream(of: RelayEvent.self)
let client = RelayClient(
    url: relayURL,
    secret: secret,
    handler: router,
    appVersion: "cli-0.0.1",
    queueKey: queueKey,
    ledger: QueueLedger(file: queueKeyArg.map { URL(fileURLWithPath: $0 + ".finished.json") }),
    onStatus: { status in
        switch status {
        case .connecting: stderrLog("relay: connecting to \(relayURL.absoluteString)")
        case .connected: stderrLog("relay: connected")
        case .disconnected(let reason): stderrLog("relay: disconnected (\(reason))")
        }
    },
    onEvent: { eventSink.yield($0) }
)

// Apps connecting through the relay need the owner's approval: ask on the terminal.
Task {
    for await event in events {
        switch event {
        case .pairingRequested(let request):
            let origin = request.clientDomain.map { "published by \($0)" } ?? "unverified name"
            let answer = await prompt.ask("""

                \(request.clientName) (\(origin)) wants to connect; access goes to \(request.redirectHost).
                Check that the browser shows code \(request.formattedCode).
                Allow? [y/N]
                """)
            let allow = answer.hasPrefix("y")
            await client.decidePairing(request.id, allow: allow)
            stderrLog(allow ? "approved \(request.clientName)" : "declined \(request.clientName)")
        case .clientsChanged(let clients):
            let names = clients.map(\.clientName)
            stderrLog("apps with access: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
            // What each app sees, and may queue, while this host is offline.
            guard queueKey != nil else { continue }
            for clientID in Set(clients.map(\.clientID)) where !clientID.isEmpty {
                await client.sendOfflineCatalog(clientID: clientID, catalog: await router.offlineCatalog(for: clientID))
            }
        case .queuedFinished(let item, let outcome):
            stderrLog("queued request from \(item.clientName), made \(item.queuedAt.formatted(.relative(presentation: .named))): \(outcome)")
        }
    }
}

let runner = Task { await client.run() }

// On Ctrl-C or SIGTERM, stop serving; the child servers are stopped below.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signals = [SIGINT, SIGTERM].map { sig in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { @Sendable in runner.cancel() }
    source.resume()
    return source
}

// Top-level code is async (it awaits above), so the main queue is already serviced and
// dispatchMain() would trap. Instead, wait here until a signal cancels the runner.
await runner.value
await router.stopAll()
