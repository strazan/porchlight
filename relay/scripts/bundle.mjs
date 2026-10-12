// Builds the relay into a single module for the Mac app to deploy through the Cloudflare
// API, next to the settings wrangler would send with it (from wrangler.jsonc, so the app
// doesn't repeat them). Run with `npm run bundle`; `npm run bundle:check` only verifies that
// the app's copy is current (exits 1 if not).
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// wrangler.jsonc can't list secrets, only mention them.
const SECRETS = ["HOST_SECRET"];

const out = new URL("../../app/Porchlight/Relay/", import.meta.url).pathname;
const check = process.argv.includes("--check");
const build = mkdtempSync(join(tmpdir(), "porchlight-relay-"));
try {
	execFileSync("npx", ["wrangler", "deploy", "--dry-run", "--outdir", build], { stdio: check ? "ignore" : "inherit" });
	const module = readFileSync(join(build, "worker.js"));
	const config = parseJSONC(readFileSync(new URL("../wrangler.jsonc", import.meta.url), "utf8"));
	const manifest = {
		main_module: "worker.js",
		compatibility_date: config.compatibility_date,
		compatibility_flags: config.compatibility_flags ?? [],
		// In the Cloudflare upload API's shape. The app fills in the KV namespace it creates
		// and the secret it generates.
		bindings: [
			...config.durable_objects.bindings.map((b) => ({ type: "durable_object_namespace", name: b.name, class_name: b.class_name })),
			...config.kv_namespaces.map((kv) => ({ type: "kv_namespace", name: kv.binding })),
			...SECRETS.map((name) => ({ type: "secret_text", name })),
		],
		// Applied when the script is first created: every migration at once.
		migration: {
			new_tag: config.migrations.at(-1).tag,
			new_sqlite_classes: config.migrations.flatMap((m) => m.new_sqlite_classes ?? []),
		},
		observability: config.observability ?? { enabled: false },
		sha256: createHash("sha256").update(module).digest("hex"),
	};
	if (check) {
		const current = JSON.parse(readFileSync(join(out, "relay-bundle.json"), "utf8"));
		const fresh = JSON.stringify(current) === JSON.stringify(manifest);
		console.log(fresh ? "relay bundle is up to date" : "relay bundle is stale: run `make relay-bundle`");
		process.exitCode = fresh ? 0 : 1;
	} else {
		writeFileSync(join(out, "relay-worker.js"), module);
		writeFileSync(join(out, "relay-bundle.json"), `${JSON.stringify(manifest, null, 2)}\n`);
		console.log(`relay bundle ${manifest.sha256.slice(0, 12)} → ${out}`);
	}
} finally {
	rmSync(build, { recursive: true, force: true });
}

/** JSON with comments and trailing commas, as wrangler.jsonc allows. */
function parseJSONC(text) {
	let json = "";
	for (let i = 0; i < text.length; i++) {
		const char = text[i];
		if (char === '"') {
			const start = i;
			for (i++; i < text.length && text[i] !== '"'; i++) if (text[i] === "\\") i++;
			json += text.slice(start, i + 1);
		} else if (char === "/" && text[i + 1] === "/") {
			while (i < text.length && text[i] !== "\n") i++;
			json += "\n";
		} else if (char === "/" && text[i + 1] === "*") {
			i = text.indexOf("*/", i + 2) + 1;
		} else {
			json += char;
		}
	}
	return JSON.parse(json.replace(/,(\s*[}\]])/g, "$1"));
}
