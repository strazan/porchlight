import Foundation
import PorchlightCore

let usage = """
    Usage: porchlight-cli --relay <url> [--name <name>] -- <command> [args...]
           porchlight-cli --relay <url> [--config <servers.json>]

    Connects to a Porchlight relay and serves local stdio MCP servers through it: all of
    them combined at <relay>/mcp, and each one at <relay>/mcp/<name>.

      --relay <url>      Relay URL, e.g. https://porchlight-relay.you.workers.dev
      --name <name>      Name for a server given after -- (default: "default")
      --config <file>    Server list to serve (default: the Porchlight app's list)

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
    case "--": command = Array(args); args.removeAll()
    case "-h", "--help": print(usage); exit(0)
    default: fail("unknown argument \(arg)")
    }
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

let servers: [ServerConfig]
if !command.isEmpty {
    servers = [ServerConfig(name: name, command: command[0], args: Array(command.dropFirst()))]
} else {
    let store = configArg.map { ServerStore(url: URL(fileURLWithPath: $0)) } ?? .standard
    guard let loaded = store.load(), !loaded.isEmpty else {
        fail("no servers: pass a command after --, or a --config file (looked in \(store.url.path))")
    }
    servers = loaded
}

let router = Router(environment: ProcessInfo.processInfo.environment)
await router.apply(servers)
for server in servers where server.enabled {
    stderrLog("serving \(server.name): \(server.commandLineString)")
}

let (events, eventSink) = AsyncStream.makeStream(of: RelayEvent.self)
let client = RelayClient(
    url: relayURL,
    secret: secret,
    handler: router,
    appVersion: "cli-0.0.1",
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
            stderrLog("""

                \(request.clientName) (\(origin)) wants to connect; access goes to \(request.redirectHost).
                Check that the browser shows code \(request.formattedCode).
                """)
            FileHandle.standardError.write(Data("Allow? [y/N] ".utf8))
            // No terminal (or end of input) means no.
            let answer = await Task.detached { readLine() }.value
            let allow = answer?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("y") == true
            await client.decidePairing(request.id, allow: allow)
            stderrLog(allow ? "approved \(request.clientName)" : "declined \(request.clientName)")
        case .clientsChanged(let clients):
            let names = clients.map(\.clientName)
            stderrLog("apps with access: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
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
