// End-to-end: drives the official MCP TypeScript SDK through Porchlight's OAuth and
// pairing flow, then calls tools on the combined and per-server endpoints.
//
// Needs a running relay and a host that approves the pairing, e.g.:
//   npx wrangler dev
//   yes y | porchlight-cli --relay http://localhost:8787 --config servers.json
// where servers.json has an `everything` (server-everything) and a `files`
// (server-filesystem) server. Then: npm run e2e
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { UnauthorizedError } from "@modelcontextprotocol/sdk/client/auth.js";

const RELAY = process.env.RELAY ?? "http://localhost:8787";
const log = (...a) => console.log("•", ...a);

class Provider {
  authorizations = 0;
  get redirectUrl() { return "http://localhost:9999/callback"; }
  get clientMetadata() {
    return { client_name: "SDK E2E", redirect_uris: [this.redirectUrl], grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"], token_endpoint_auth_method: "none" };
  }
  clientInformation() { return this.client; }
  saveClientInformation(info) { this.client = info; log("registered client", info.client_id); }
  tokens() { return this._tokens; }
  saveTokens(tokens) { this._tokens = tokens; log("got tokens; refresh token:", Boolean(tokens.refresh_token)); }
  redirectToAuthorization(url) { this.authorizations++; this.authUrl = url; log("authorize resource =", url.searchParams.get("resource")); }
  saveCodeVerifier(v) { this.verifier = v; }
  codeVerifier() { return this.verifier; }
}

/** What the user's browser does on the consent page. */
async function consentPage(authUrl) {
  const page = await fetch(authUrl, { redirect: "manual" });
  const cookie = page.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
  const html = await page.text();
  const field = (n) => html.match(new RegExp(`name="${n}" value="([^"]*)"`))?.[1] ?? "";
  log("consent page shows code", html.match(/class="code">([^<]+)</)?.[1]);
  const pairing = field("pairing");
  if (!pairing) throw new Error("The consent page says Porchlight is offline. Is it running and connected?");
  for (;;) {
    const { state } = await (await fetch(`${RELAY}/authorize/status?id=${pairing}`)).json();
    if (state === "approved") break;
    if (state !== "pending") throw new Error(`pairing ${state}`);
    await new Promise((r) => setTimeout(r, 300));
  }
  const res = await fetch(`${RELAY}/authorize`, {
    method: "POST", redirect: "manual",
    headers: { cookie, "content-type": "application/x-www-form-urlencoded", origin: RELAY },
    body: new URLSearchParams({ handle: field("handle"), pairing, decision: "approve" }),
  });
  return new URL(res.headers.get("location")).searchParams.get("code");
}

async function connect(path, provider) {
  const url = new URL(path, RELAY);
  const client = new Client({ name: "e2e", version: "1" });
  try {
    await client.connect(new StreamableHTTPClientTransport(url, { authProvider: provider }));
  } catch (error) {
    if (!(error instanceof UnauthorizedError)) throw error;
    const transport = new StreamableHTTPClientTransport(url, { authProvider: provider });
    await transport.finishAuth(await consentPage(provider.authUrl));
    await client.connect(new StreamableHTTPClientTransport(url, { authProvider: provider }));
  }
  return client;
}

const provider = new Provider();
const all = await connect("/mcp", provider);
log("connected to /mcp as", all.getServerVersion()?.name);
const { tools } = await all.listTools();
log(`${tools.length} tools, e.g.`, tools.slice(0, 2).map((t) => t.name).join(", "));
const sum = await all.callTool({ name: "everything__get-sum", arguments: { a: 2, b: 40 } });
log("everything__get-sum →", sum.content[0].text);
// Not read-only: under the default permissions the host must approve it (the CLI answers "y").
const toggled = await all.callTool({ name: "everything__toggle-simulated-logging", arguments: {} });
log("everything__toggle-simulated-logging →", toggled.isError ? `declined: ${toggled.content[0].text}` : toggled.content[0].text);

const files = await connect("/mcp/files", provider);
log("connected to /mcp/files as", files.getServerVersion()?.name);
log("files tools:", (await files.listTools()).tools.slice(0, 3).map((t) => t.name).join(", "));
log("authorizations needed in total:", provider.authorizations);

await all.close();
await files.close();
