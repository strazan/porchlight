import Foundation
import PorchlightCore

let usage = """
    Usage: porchlight-cli --relay <url> [--name <name>] -- <command> [args...]

    Connects to a Porchlight relay and serves one local stdio MCP server through it,
    at <relay>/mcp and <relay>/s/<name>/mcp.

      --relay <url>   Relay URL, e.g. https://porchlight-relay.you.workers.dev
      --name <name>   Server name for the per-server endpoint (default: "default")

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
    case "--": command = Array(args); args.removeAll()
    case "-h", "--help": print(usage); exit(0)
    default: fail("unknown argument \(arg)")
    }
}
guard let relayArg else { fail("--relay is required") }
guard !command.isEmpty else { fail("missing server command after --") }
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

let bridge = StdioBridge(name: name, command: command)
let client = RelayClient(url: relayURL, secret: secret, handler: bridge, appVersion: "cli-0.0.1") { status in
    switch status {
    case .connecting: stderrLog("relay: connecting to \(relayURL.absoluteString)")
    case .connected: stderrLog("relay: connected")
    case .disconnected(let reason): stderrLog("relay: disconnected (\(reason))")
    }
}

let runner = Task { await client.run() }

// Stop the child server too on Ctrl-C.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signals = [SIGINT, SIGTERM].map { sig in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { @Sendable in
        runner.cancel()
        Task {
            await bridge.stop()
            exit(0)
        }
    }
    source.resume()
    return source
}

dispatchMain()
