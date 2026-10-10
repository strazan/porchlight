# Porchlight

Use the MCP servers on your Mac from Claude.ai, ChatGPT, and other cloud AI clients.

Cloud clients can only connect to MCP servers at a public HTTPS URL, but most useful
servers are local stdio processes. Porchlight runs a small relay **in your own
Cloudflare account** and keeps an outbound connection to it from your Mac, so there are
no open ports, no ngrok, and no URL that changes every time.

```
Claude.ai / ChatGPT ──HTTPS──▶ your relay (Cloudflare Worker + Durable Object)
                                     ▲
                                     │ outbound WebSocket
                               your Mac: Porchlight ──stdio──▶ MCP servers
```

> **Status: early.** The menubar app runs your servers and serves them through your
> relay, combined at `/mcp` and one by one at `/mcp/<name>`. Apps connect with OAuth,
> and you approve each one on your Mac. One-click deploy comes next. See the roadmap below.

## Repository

| Path | What |
|---|---|
| `relay/` | The relay: a Cloudflare Worker + Durable Object (TypeScript). It tunnels HTTP over a WebSocket and doesn't parse MCP at all. |
| `app/Porchlight.xcodeproj`, `app/Porchlight/` | The macOS menubar app (SwiftUI). |
| `app/PorchlightCore/` | Swift package: `PorchlightCore` (relay client, stdio bridge) and `porchlight-cli`. |
| `protocol/PROTOCOL.md` | The wire protocol between relay and host. |

## Try it locally

Requirements: Node 20+, Xcode 26+.

```sh
cd relay && npm install && cd ..
make dev                      # relay on http://localhost:8787 (secret from relay/.dev.vars)

# in another terminal
make build-cli
PORCHLIGHT_SECRET=dev-secret-change-me app/PorchlightCore/.build/release/porchlight-cli \
  --relay http://localhost:8787 --name everything \
  -- npx -y @modelcontextprotocol/server-everything

# or serve the app's server list headless (or any servers.json):
#   app/PorchlightCore/.build/release/porchlight-cli --relay http://localhost:8787 [--config servers.json]
# The CLI asks on the terminal when an app wants to connect.

# in a third terminal: connect with MCP Inspector (choose Streamable HTTP and OAuth)
npx @modelcontextprotocol/inspector
```

Or use the menubar app instead of the CLI: `make app` builds `Porchlight.app` and opens it
(or open `app/Porchlight.xcodeproj` in Xcode and run it). Look for the lightbulb in the menubar
and enter the relay URL and secret in Settings.

You need to create `relay/.dev.vars` yourself (it's gitignored):

```
AGENT_SECRET=dev-secret-change-me
```

## Deploy your own relay

**From the app:** Settings → Relay → **Deploy to Cloudflare…** The wizard opens a
pre-filled Cloudflare API token page (Workers Scripts and Workers KV, edit), then
creates everything and connects Porchlight to the new relay. The token stays in your
Keychain so Porchlight can update the relay when a new version ships with the app.

**By hand, with wrangler:**

```sh
cd relay
npx wrangler login
openssl rand -hex 32 | npx wrangler secret put AGENT_SECRET   # shared with your Mac
npx wrangler deploy                                           # also creates the OAUTH_KV namespace
```

Then enter `https://porchlight-relay.<you>.workers.dev` and your `AGENT_SECRET` in
Settings → Relay.

**Connecting apps:** add `https://porchlight-relay.<you>.workers.dev/mcp` as a custom
connector in Claude, ChatGPT or any MCP client that supports OAuth. When it connects,
your browser shows a code and Porchlight asks you to approve the app with the same code.
Apps you've approved are listed under Settings → Apps, where you can revoke them.

## Staying in control

- **Approve each app.** A new connection shows a code in the browser and the same code
  on your Mac; nothing connects until you allow it.
- **Choose what each app can use.** When you approve an app, pick all servers or just
  some. Change it any time under Settings → Apps, or revoke the app entirely.
- **Approve tool calls.** By default Porchlight asks before any tool that doesn't
  declare itself read-only, showing the app, tool and arguments: allow once, always
  allow, or deny. Per server you can instead run tools without asking or ask before
  every tool, and set individual tools to Allow, Ask or Block (blocked tools are hidden).
- **See what happened.** The Activity window lists every request: app, tool, server,
  time taken and result.

The relay fits in Cloudflare's free tier. The Durable Object hibernates while idle,
and keepalive pings are answered without waking it.

## How it works

- Your Mac opens a WebSocket to `/agent` and authenticates with `AGENT_SECRET`.
- MCP clients authorize with OAuth 2.1 against the relay (dynamic registration or Client
  ID Metadata Documents, PKCE). The consent step is approved on your Mac.
- They then send Streamable HTTP requests to `/mcp` (or `/mcp/<server>`). The relay
  checks the token, forwards each request over the socket and streams the response back.
- On the Mac, each server runs as one child process shared by all clients. Porchlight
  does the `initialize` handshake itself (and again if the server restarts), rewrites
  JSON-RPC ids so clients can't collide, and answers `tools/call` over SSE with
  keepalives and progress notifications, so long-running tools work.
- `/mcp` combines every enabled server: tools and prompts are renamed
  `<server>__<name>`, and resources are routed by URI. `/mcp/<name>` serves one
  server unchanged.

## Roadmap

- [x] **M0**: relay + CLI host, one stdio server, end to end
- [x] **M1**: OAuth 2.1 at the relay, where you approve new clients on your Mac
- [x] **M2**: menubar app: manage servers, import from Claude Desktop/Claude Code/Cursor configs, one combined endpoint plus one per server
- [x] **M3**: one-click deploy to your Cloudflare account from the app, launch at login, reconnect on wake and network changes
- [x] **M4**: per-tool permissions with approvals, per-app server access, activity log, revoke apps
- [ ] **M5**: signed releases, Homebrew cask, self-hosted relay (Docker)

## Development

```sh
make test          # relay (vitest in workerd) + PorchlightCore (Swift Testing)
make app           # build and open the menubar app
make relay-bundle  # after changing relay/: rebuild the relay the app deploys
make release       # optimized build of the app
```

Builds are signed to run locally. To sign with your own Apple Developer team, see
`app/Config/Base.xcconfig`.

## License

MIT. See [LICENSE](LICENSE).
