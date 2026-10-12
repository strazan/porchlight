// End-to-end: drives the official MCP TypeScript SDK through Porchlight's OAuth and
// pairing flow, then calls tools on the combined and per-server endpoints.
//
// Needs a running relay and a host that approves the pairing, e.g.:
//   npx wrangler dev
//   yes y | porchlight-cli --relay http://localhost:8787 --config servers.json
// where servers.json has an `everything` (server-everything) and a `files`
// (server-filesystem) server. Then: npm run e2e
import { Provider, connect, log } from "./support.mjs";

const provider = new Provider("SDK E2E");
const all = await connect("/mcp", provider);
log("connected to /mcp as", all.getServerVersion()?.name);
const { tools } = await all.listTools();
log(`${tools.length} tools, e.g.`, tools.slice(0, 2).map((t) => t.name).join(", "));
const sum = await all.callTool({ name: "everything__get-sum", arguments: { a: 2, b: 40 } });
log("everything__get-sum →", sum.content[0].text);
// Not read-only: under the default permissions the host must approve it (the CLI answers "y").
const toggled = await all.callTool({ name: "everything__toggle-simulated-logging", arguments: {} });
log("everything__toggle-simulated-logging →", toggled.isError ? `denied: ${toggled.content[0].text}` : toggled.content[0].text);

const files = await connect("/mcp/files", provider);
log("connected to /mcp/files as", files.getServerVersion()?.name);
log("files tools:", (await files.listTools()).tools.slice(0, 3).map((t) => t.name).join(", "));
log("authorizations needed in total:", provider.authorizations);

await all.close();
await files.close();
