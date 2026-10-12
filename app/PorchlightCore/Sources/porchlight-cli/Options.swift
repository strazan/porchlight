import Foundation
import PorchlightCore

let usage = """
    Usage: porchlight-cli --relay <url> [--name <name>] -- <command> [args...]
           porchlight-cli --relay <url> [--config <servers.json>]
           porchlight-cli --check [--config <servers.json>]

    Connects to a Porchlight relay and serves local MCP servers through it, as the
    Porchlight app does: all of them combined at <relay>/mcp, and each one at
    <relay>/mcp/<name>. Servers are the app's list, a --config file, or one stdio
    command given after --.

      --relay <url>      Relay URL, e.g. https://porchlight-relay.you.workers.dev
      --name <name>      Name for the server given after -- (default: "default")
      --config <file>    Server list to serve (default: the Porchlight app's list)
      --check            Connect to each enabled server, report what answers, and exit
      --allow-tools      Run every tool without asking (default: ask on the terminal for
                         tools that don't declare themselves read-only). Tools a server's
                         settings block stay blocked.
      --queue-key <file> While this Mac is offline, let the relay save calls to tools
                         that only add something, sealed to the key in <file> (created if
                         missing), and run them when it's back

    The relay's shared secret is read from PORCHLIGHT_SECRET.

    Example:
      PORCHLIGHT_SECRET=… porchlight-cli --relay http://localhost:8787 --name everything \\
        -- npx -y @modelcontextprotocol/server-everything
    """

func fail(_ message: String) -> Never {
    stderrLog("error: \(message)\n\n\(usage)")
    exit(EX_USAGE)
}

/// The command line, parsed.
struct Options {
    var relay: String?
    var config: String?
    var checkOnly = false
    var allowTools = false
    var queueKey: String?
    var name = "default"
    /// A stdio server given after `--`.
    var command: [String] = []

    init(_ arguments: ArraySlice<String>) {
        var args = arguments
        while let arg = args.popFirst() {
            switch arg {
            case "--relay": relay = Self.value(for: arg, &args)
            case "--name": name = Self.value(for: arg, &args)
            case "--config": config = Self.value(for: arg, &args)
            case "--queue-key": queueKey = Self.value(for: arg, &args)
            case "--check": checkOnly = true
            case "--allow-tools": allowTools = true
            case "--":
                command = Array(args)
                args.removeAll()
            case "-h", "--help":
                print(usage)
                exit(0)
            default: fail("unknown argument \(arg)")
            }
        }
        guard ServerConfig.isValidName(name) else { fail("--name must be lowercase letters, digits and hyphens") }
        if name != "default", command.isEmpty { fail("--name names the server given after --") }
    }

    private static func value(for flag: String, _ args: inout ArraySlice<String>) -> String {
        guard let value = args.popFirst() else { fail("\(flag) needs a value") }
        return value
    }

    /// The servers to serve: the command after `--`, else the config file or the app's list.
    func servers() -> [ServerConfig] {
        var servers: [ServerConfig]
        if command.isEmpty {
            let store = config.map { ServerStore(url: URL(fileURLWithPath: $0)) } ?? .standard
            do {
                guard let loaded = try store.load(), !loaded.isEmpty else {
                    fail("no servers: pass a command after --, or a --config file (looked in \(store.url.path))")
                }
                servers = loaded
            } catch {
                fail("can't read \(store.url.path): \(error.localizedDescription)")
            }
        } else {
            servers = [ServerConfig(name: name, command: command[0], args: Array(command.dropFirst()))]
        }
        if allowTools {
            for index in servers.indices { servers[index].toolPolicy.defaultPermission = .allowAll }
        }
        return servers
    }

    /// The relay's WebSocket endpoint, from its public URL.
    func hostURL() -> URL? {
        guard let relay, var components = URLComponents(string: relay) else { return nil }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        case "wss", "ws": break
        default: return nil
        }
        if components.path.isEmpty || components.path == "/" { components.path = "/host" }
        return components.url
    }
}
