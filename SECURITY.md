# Security

Porchlight gives cloud agents access to MCP servers on a Mac, so security reports are a
priority.

## Reporting a vulnerability

Report it privately through
[GitHub security advisories](https://github.com/strazan/porchlight/security/advisories/new),
not in a public issue. Include a description, steps to reproduce, and the impact. Reports
get a response within a few days, and reporters are credited in the release notes on
request.

## In scope

- The relay (`relay/`): OAuth, pairing, the tunnel, the offline queue
- The Mac app and `porchlight-cli` (`app/`): permissions, per-app access, approvals, how
  servers are started and what they're sent
- The protocol between them (`protocol/PROTOCOL.md`)

Vulnerabilities in third-party MCP servers, or in Claude, ChatGPT or Cloudflare, should be
reported to their maintainers.

## Design

The [security docs](https://porchlight.sh/docs/#security) describe the model: the relay
runs in the owner's Cloudflare account, the Mac only connects outbound, every app is
approved on the Mac, and tools that change things ask first.
