// End-to-end check of the offline queue, with the official MCP SDK as the app:
//   1. a CLI host serves a test server; the SDK connects (the CLI approves the pairing)
//   2. the host goes away; the SDK still lists tools, and a call to an additive tool is saved
//   3. the host comes back with the same queue key and runs the saved call
//
// Needs `npx wrangler dev` (with HOST_SECRET in .dev.vars) and a built CLI
// (`swift build` in app/PorchlightCore). Then: npm run e2e:queue
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Provider, RELAY, check, connect, log, sleep } from "./support.mjs";

const root = fileURLToPath(new URL("../../", import.meta.url));
const CLI = join(root, "app/PorchlightCore/.build/debug/porchlight-cli");
const FAKE = join(root, "app/PorchlightCore/Tests/PorchlightCoreTests/Fixtures/fake_server.py");
const SECRET = readFileSync(new URL("../.dev.vars", import.meta.url), "utf8").match(/HOST_SECRET=(.*)/)[1].trim();

const dir = mkdtempSync(join(tmpdir(), "porchlight-queue-"));
const config = join(dir, "servers.json");
writeFileSync(config, JSON.stringify([{
	id: "6D2B7C40-1F0E-4C55-9A0B-3C1D2E4F5A6B", name: "notes", transport: "stdio", command: "python3",
	args: ["-u", FAKE], env: { FAKE_NAME: "notes", FAKE_MORE_TOOLS: "1" }, headers: {}, url: "", enabled: true,
	toolPolicy: { defaultPermission: "askForChanges", overrides: {} },
}]));

/** The CLI as a host, answering yes to everything it asks. */
function startHost() {
	const proc = spawn("sh", ["-c", `yes y | "${CLI}" --relay ${RELAY} --config "${config}" --queue-key "${join(dir, "queue.key")}"`], {
		env: { ...process.env, PORCHLIGHT_SECRET: SECRET }, detached: true, stdio: ["ignore", "ignore", "pipe"],
	});
	let output = "";
	proc.stderr.on("data", (chunk) => (output += chunk));
	return {
		async waitFor(pattern, ms = 20_000) {
			for (const end = Date.now() + ms; Date.now() < end; await sleep(100)) if (pattern.test(output)) return;
			throw new Error(`host never printed ${pattern}:\n${output}`);
		},
		stop() {
			const exited = new Promise((resolve) => proc.once("exit", resolve));
			process.kill(-proc.pid, "SIGTERM");
			return exited;
		},
	};
}

const first = startHost();
await first.waitFor(/relay: connected/);
const provider = new Provider("Queue E2E");
const online = await connect("/mcp", provider);
const onlineTools = (await online.listTools()).tools.map((t) => t.name);
check(onlineTools.includes("notes__add"), `online tools: ${onlineTools.join(", ")}`);
await first.waitFor(/apps with access: .*Queue E2E[^]*offline catalogs sent/);
await first.stop();
log("host stopped");

const offline = await connect("/mcp", provider);
const offlineTools = (await offline.listTools()).tools.map((t) => t.name);
check(offlineTools.join() === onlineTools.join(), "offline, the app still sees the same tools");
const saved = await offline.callTool({ name: "notes__add", arguments: { text: "oat milk" } });
check(!saved.isError && saved.content[0].text.includes("saved this request"), `additive call saved: "${saved.content[0].text}"`);
const refused = await offline.callTool({ name: "notes__remove", arguments: {} });
check(refused.isError === true, `destructive call refused: "${refused.content[0].text}"`);

const second = startHost();
await second.waitFor(/queued request from Queue E2E, made .*: ran/);
check(true, "the host ran the saved call when it came back");
await second.stop();
await online.close();
await offline.close();
log("offline queue works end to end");
