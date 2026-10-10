# Porchlight relay protocol — v1

The relay (a Cloudflare Worker + Durable Object, or any compatible server) and the
host (the Porchlight app on your Mac) talk over a single WebSocket that the **host
opens outbound**. The relay never connects to the host.

The relay is deliberately MCP-agnostic: it tunnels raw HTTP requests to the host and
streams raw HTTP responses back. All MCP logic (Streamable HTTP, aggregation,
policy) lives on the host.

## Connecting

```
GET /agent
Upgrade: websocket
Authorization: Bearer <AGENT_SECRET>
Porchlight-Protocol: 1
```

- `AGENT_SECRET` is a long random secret shared between relay and host.
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
| `pong` | — | Reply to the host's `ping`. |

### Host → relay

| type | fields | meaning |
|---|---|---|
| `hello` | `proto`, `app_version` | First frame after connecting. |
| `res_start` | `id`, `status`, `headers` | Begin the response. Exactly once per `req`. |
| `res_chunk` | `id`, `data_b64` | Part of the response body. Zero or more. |
| `res_end` | `id` | Response complete. |
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

The relay strips hop-by-hop headers and `Authorization` before forwarding
(from v1/M1 onward, it adds `Porchlight-Client-*` identity headers instead). The
host must not trust headers the relay did not set.

## Timeouts and errors (relay behavior)

- No host connected → `503` with a JSON-RPC error body:
  `{"jsonrpc":"2.0","id":<id or null>,"error":{"code":-32001,"message":"Porchlight host is offline"}}`
- No `res_start` within 60 s → `504`.
- Host disconnects mid-response → the stream is aborted.
