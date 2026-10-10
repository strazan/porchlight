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
> relay, combined at `/mcp` and one by one at `/s/<name>/mcp`. OAuth and one-click
> deploy come next. See the roadmap below.

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

# in a third terminal
npx @modelcontextprotocol/inspector --cli http://localhost:8787/mcp \
  --transport http --method tools/list
```

Or use the menubar app instead of the CLI: `make app` builds `Porchlight.app` and opens it
(or open `app/Porchlight.xcodeproj` in Xcode and run it). Look for the lightbulb in the menubar
and enter the relay URL and secret in Settings.

You need to create `relay/.dev.vars` yourself (it's gitignored):

```
AGENT_SECRET=dev-secret-change-me
```

## Deploy your own relay

```sh
cd relay
npx wrangler login
openssl rand -hex 32 | npx wrangler secret put AGENT_SECRET   # shared with your Mac
openssl rand -hex 32 | npx wrangler secret put CLIENT_KEY     # see the warning below
npx wrangler deploy
```

Then run the CLI with `--relay https://porchlight-relay.<you>.workers.dev` and
`PORCHLIGHT_SECRET` set to your `AGENT_SECRET`. In Claude.ai, add a custom connector
with the URL `https://porchlight-relay.<you>.workers.dev/mcp?key=<CLIENT_KEY>`.

> ⚠️ **Until OAuth lands (M1), `CLIENT_KEY` is the only thing between the internet and
> the tools on your Mac.** Always set it, keep the URL private, and only expose servers
> you'd be comfortable with a cloud model driving.

The relay fits in Cloudflare's free tier. The Durable Object hibernates while idle,
and keepalive pings are answered without waking it.

## How it works

- Your Mac opens a WebSocket to `/agent` and authenticates with `AGENT_SECRET`.
- MCP clients send Streamable HTTP requests to `/mcp` (or `/s/<server>/mcp`). The relay
  forwards each request over the socket and streams the response back.
- On the Mac, each server runs as one child process shared by all clients. Porchlight
  does the `initialize` handshake itself (and again if the server restarts), rewrites
  JSON-RPC ids so clients can't collide, and answers `tools/call` over SSE with
  keepalives and progress notifications, so long-running tools work.
- `/mcp` combines every enabled server: tools and prompts are renamed
  `<server>__<name>`, and resources are routed by URI. `/s/<name>/mcp` serves one
  server unchanged.

## Roadmap

- [x] **M0**: relay + CLI host, one stdio server, end to end
- [ ] **M1**: OAuth 2.1 at the relay, where you approve new clients on your Mac
- [x] **M2**: menubar app: manage servers, import from Claude Desktop/Claude Code/Cursor configs, one combined endpoint plus one per server
- [ ] **M3**: one-click deploy to your Cloudflare account from the app, Keychain, launch at login
- [ ] **M4**: per-tool policies (allow / ask / deny), approvals, activity log, revoke clients
- [ ] **M5**: signed releases, Homebrew cask, self-hosted relay (Docker)

## Development

```sh
make test        # relay (vitest in workerd) + PorchlightCore (Swift Testing)
make app         # build and open the menubar app
```
