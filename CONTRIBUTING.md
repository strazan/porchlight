# Contributing to Porchlight

How the project is put together, and how to work on it.

## What's where

| Path | What |
|---|---|
| `app/Porchlight/` | The macOS menu bar app (SwiftUI), built with `app/Porchlight.xcodeproj` |
| `app/PorchlightCore/` | Swift package with everything that isn't UI: the relay client, the router and aggregator, stdio and HTTP upstreams, permissions, the Cloudflare deployer, and `porchlight-cli` |
| `relay/` | The relay: a Cloudflare Worker and Durable Object (TypeScript). It's the OAuth server for MCP clients and tunnels their requests to the Mac over a WebSocket |
| `relay/e2e/` | End-to-end checks with the official MCP SDK as the app |
| `protocol/` | The protocol between the relay and the Mac (`PROTOCOL.md`), and test vectors both sides check |
| `docs/` | The website, porchlight.sh (`site/` publishes it with Cloudflare Workers) |
| `design/` | Sources for the README's images |
| `scripts/` | Release tooling |

A request travels like this: an MCP client calls `<relay>/mcp` with an OAuth token → the
relay checks it and forwards the raw HTTP request over the Mac's WebSocket → the
`Router` in PorchlightCore picks the combined endpoint (`/mcp`) or one server
(`/mcp/<name>`), applies per-app access and tool permissions, and talks to the server
over stdio or HTTP → the response streams back the same way. While the Mac is online the
relay doesn't parse MCP; all of that lives in Swift. Its one exception is answering from
an app's offline catalog while the Mac is away.

## Requirements

- macOS 14 or later, Xcode 26 or later
- Node 20.19 or later (for the relay)
- Python 3, which the Swift tests use for their fake MCP servers (macOS has it)

## Common tasks

```sh
make test          # relay tests (vitest in workerd) + PorchlightCore tests (Swift Testing);
                   # installs the relay's dependencies the first time
make app           # build and open the app
make release       # optimized universal build
make snapshots     # render every screen, light and dark, to app/build/snapshots
make relay-bundle  # after changing relay/: rebuild the relay the app deploys
```

`make test` also fails if the relay bundled into the app is out of date with `relay/`.
Run `make relay-bundle` and commit the result.

### Snapshots

`make snapshots` renders every screen with sample data (it never touches the real
settings), for reviewing UI changes without clicking through the app. Variations:

- `PORCHLIGHT_SNAPSHOTS_ONLINE=1`: fetch real app and server icons
- `PORCHLIGHT_SNAPSHOTS_SCREEN=1`: capture real windows with `screencapture` (exact colors
  and shadows, as used on the website; needs Screen Recording permission, and windows
  appear on screen briefly)
- `PORCHLIGHT_SNAPSHOTS_ONLY=menu,prompt`: only screens whose names contain these

## Running everything locally

The whole chain runs locally, without Cloudflare:

```sh
cd relay && npm ci
echo "HOST_SECRET=dev-secret" > .dev.vars
npx wrangler dev                     # relay on http://localhost:8787
```

Then point the app at it (Settings → Relay → "Use a relay you deployed yourself":
`http://localhost:8787` and `dev-secret`), or use the CLI:

```sh
cd app/PorchlightCore && swift build
PORCHLIGHT_SECRET=dev-secret .build/debug/porchlight-cli --relay http://localhost:8787 \
  --name everything -- npx -y @modelcontextprotocol/server-everything
```

The CLI serves the app's server list when given no command, and asks on the terminal when
an app wants to connect or call a tool. `--check` tests every server and exits,
`--allow-tools` runs tools without asking (blocked ones stay blocked), and `--queue-key
<file>` turns on the offline queue. `porchlight-cli --help` lists everything. Set
`PORCHLIGHT_DEBUG=1` to trace the relay connection (pings, reconnects) on stderr.

Connect a client with [MCP Inspector](https://github.com/modelcontextprotocol/inspector)
(`npx @modelcontextprotocol/inspector`, Streamable HTTP, `http://localhost:8787/mcp`). For
an automated end-to-end check with the official MCP SDK, run a CLI host that approves
everything and then `npm run e2e` in `relay/` (see the comment at the top of
`relay/e2e/sdk-oauth.mjs`). `npm run e2e:queue` checks the offline queue the same way:
it stops and restarts a CLI host around a call made while it's away.

## Code signing

Builds are signed to run locally by default. To sign with an Apple Developer team
(a stable signature, so the Keychain stops asking after every rebuild), create
`app/Config/Signing.local.xcconfig`. It's gitignored; see `app/Config/Base.xcconfig`.

## Releasing

Maintainers: `scripts/release.sh <version>` builds a Developer ID-signed, notarized zip
and its Homebrew cask in `app/build/release`. With `--publish` it also tags the release,
creates the GitHub release and updates
[strazan/homebrew-tap](https://github.com/strazan/homebrew-tap). The script's header
lists the one-time setup (a notarytool profile and the GitHub CLI).

## Style

- Match the surrounding code; comments explain why, not what.
- Keep the relay MCP-agnostic (apart from the offline path); protocol logic belongs in
  PorchlightCore.
- New behavior comes with tests. UI changes: check `make snapshots` in light and dark.
