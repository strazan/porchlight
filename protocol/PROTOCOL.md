# Porchlight relay protocol — v1

The relay (a Cloudflare Worker + Durable Object, or any compatible server) and the
host (the Porchlight app on your Mac) talk over a single WebSocket that the **host
opens outbound**. The relay never connects to the host.

The relay is deliberately MCP-agnostic: it tunnels raw HTTP requests to the host and
streams raw HTTP responses back. All MCP logic (Streamable HTTP, aggregation,
policy) lives on the host. The relay's own jobs are OAuth (it is the authorization
server for `<origin>/mcp`, which by path prefix also covers `/mcp/<name>`) and asking
the host to approve new clients.

## Connecting

```
GET /host
Upgrade: websocket
Authorization: Bearer <HOST_SECRET>
Porchlight-Protocol: 1
```

- `HOST_SECRET` is a long random secret shared between relay and host.
- The relay rejects mismatched secrets with `401` and unsupported protocol
  versions with `426`.
- Only one host may be connected. A new host connection replaces the old one
  (the old socket is closed with code `4000`, reason `replaced`).

## Frames

Every WebSocket message is a UTF-8 JSON object with a `type` field. Bodies and
chunks are base64 (`*_b64`) so that frames stay valid JSON.

### Relay → host

| type | fields | meaning |
|---|---|---|
| `req` | `id`, `method`, `path`, `headers` (`[[name, value], …]`), `body_b64` | An incoming HTTP request. `path` includes the query string. |
| `cancel` | `id` | The client went away; stop work and send nothing more for `id`. |
| `pair_request` | `id`, `code`, `client_id`, `client_name`, `client_domain?`, `redirect_host`, `loopback` | An app is on the consent page. Show its details and `code` (the page shows the same code) and answer with `pair_decision`. Re-sent on reconnect while pending; expires after 10 minutes. At most 5 wait at once (anyone can open the consent page); more get a "try again later" page. `client_name` is one plain line of at most 80 characters. |
| `clients` | `items: [{grant_id, client_id, client_name, client_domain?, created_at}]` | The apps that currently have access. Sent after `list_clients`, after a pairing completes, and after `revoke_client`. |
| `queued` | `id`, `client_id`, `client_name`, `path`, `queued_at` (Unix ms), `sealed` | A request saved while the host was offline (see [Offline queue](#offline-queue)). Sent on connect, oldest first, and again on every connect until `queued_done`. |
| `pong` | — | Reply to the host's `ping`. |

### Host → relay

| type | fields | meaning |
|---|---|---|
| `hello` | `proto`, `app_version`, `queue_key?` | First frame after connecting. `queue_key`: the host's P-256 public key (uncompressed point, base64) that queued requests are sealed to; without it, nothing is queued. |
| `res_start` | `id`, `status`, `headers` | Begin the response. Exactly once per `req`. |
| `res_chunk` | `id`, `data_b64` | Part of the response body. Zero or more. |
| `res_end` | `id` | Response complete. |
| `pair_decision` | `id`, `allow` | The owner's answer to a `pair_request`. |
| `list_clients` | — | Ask for a `clients` frame. |
| `revoke_client` | `grant_id` | Revoke an app's access immediately: the relay refuses the grant's requests from then on (even with a token KV hasn't deleted yet), ends ones in flight, and drops what it queued. |
| `offline_catalog` | `client_id`, `catalog` (or `null` to forget) | What this app sees while the host is offline. |
| `queued_done` | `id` | A `queued` request has been handled (run, declined or unreadable); the relay deletes it. |
| `ping` | — | Keepalive, every ~30 s. Must be exactly `{"type":"ping"}` (see below). |

A host that cannot produce a response sends `res_start` with a 5xx status followed by
`res_end`.

## Keepalive

The host sends the literal message `{"type":"ping"}` and the relay answers the literal
message `{"type":"pong"}`. Because both are exact strings, the Cloudflare relay answers
them with `setWebSocketAutoResponse`, without waking the hibernated Durable Object, so an
idle connection costs nothing. If the host gets no `pong` within ~10 s, it should
reconnect.

## Request IDs

`id` is an opaque string chosen by the relay, unique for the lifetime of the
connection. The host must not assume ordering. Multiple requests are in flight
concurrently, and SSE responses may stay open for a long time.

## Header handling

The relay strips hop-by-hop headers and `Authorization` before forwarding, and replaces
any `Porchlight-*` headers from the client with its own:

- `Porchlight-Client-Id`: the OAuth client ID (URI-encoded)
- `Porchlight-Client-Name`: the name the owner approved (URI-encoded)

## Timeouts and errors (relay behavior)

- No host connected, and no offline catalog for the app (or the path) → `503` with a
  JSON-RPC error body:
  `{"jsonrpc":"2.0","id":<id or null>,"error":{"code":-32001,"message":"The Mac running Porchlight is offline"}}`
- No `res_start` within 60 s → `504`.
- Host disconnects before `res_start` → `502`; after it → the stream ends where it is.

## Offline queue

While the host is connected, the relay never reads MCP. While it's offline, the relay
answers from the app's **catalog**, the last `offline_catalog` the host sent for that
`client_id`:

```json
{
  "protocol_versions": ["2025-11-25", "2025-06-18"],
  "paths": {
    "/mcp": { "initialize": { … }, "tools": [ … ], "queueable": ["reminders__create_reminder"] },
    "/mcp/reminders": { "initialize": { … }, "tools": [ … ], "queueable": ["create_reminder"] }
  }
}
```

The host sends one per app with access, when it connects and when servers, permissions
or access change. Offline, for a path in the catalog:

- `initialize` returns the catalog's result (with the client's protocol version if listed),
  `tools/list` its tools, `ping` an empty result, and `prompts/list`, `resources/list` and
  `resources/templates/list` empty lists. Notifications get `202`.
- `tools/call` to a tool in `queueable` is saved and answered with a tool result saying so.
  Any other `tools/call` gets a tool result with `isError: true` saying the Mac is offline.
  Other methods get the `-32001` error.

A saved request keeps the app's identity, the path and the JSON-RPC message, **sealed** to
the host's `queue_key`: ECDH with an ephemeral P-256 key, HKDF-SHA256 (empty salt, info
`porchlight-queue-v1`) to an AES-256-GCM key, with the item's `id` as associated data.
`sealed` is base64 of ephemeral public key (65 bytes) ‖ nonce (12) ‖ ciphertext and tag.
`vectors/queue.json` is a test vector both sides check.

The relay keeps at most 100 saved requests, of up to 256 KB each, for 7 days. The host
runs each like a live request (same access rules and permissions; the owner may be asked),
remembers which ids it has finished so a resent one never runs twice, and answers
`queued_done` once it's handled.
