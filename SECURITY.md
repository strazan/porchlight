# Security

Porchlight gives cloud agents a way into the MCP servers on your Mac, so we take reports
seriously.

## Reporting a vulnerability

Please report it privately through
[GitHub security advisories](https://github.com/strazan/porchlight/security/advisories/new),
not in a public issue. Include what you found, how to reproduce it, and what an attacker
could do with it. You'll get an answer within a few days, and credit in the release notes
if you'd like.

## In scope

- The relay (`relay/`): OAuth, pairing, the tunnel, the offline queue
- The Mac app and `porchlight-cli` (`app/`): permissions, per-app access, approvals, how
  servers are started and what they're sent
- The protocol between them (`protocol/PROTOCOL.md`)

Bugs in the MCP servers you add, or in Claude, ChatGPT or Cloudflare themselves, are for
their own maintainers.

## How it's built to be safe

The [docs](https://porchlight.sh/docs/#security) describe the design: the relay runs in
your own Cloudflare account, your Mac only connects out, every app is approved on your Mac,
and tools that change things ask first.
