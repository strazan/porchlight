import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import vector from "../../protocol/vectors/queue.json";
import { fromBase64, toBase64 } from "../src/bytes";
import type { Catalog } from "../src/protocol";
import { MAX_QUEUED, QUEUE_TTL_MS } from "../src/queue";
import { open, seal } from "../src/seal";
import { clearStorage, connectHost, dec, enc, hubStub, mcp, pair } from "./helpers";

const catalog = (queueable = ["notes__add"]): Catalog => ({
	protocol_versions: ["2025-06-18", "2025-03-26"],
	paths: {
		"/mcp": {
			initialize: { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "porchlight" } },
			tools: [{ name: "notes__add" }, { name: "notes__read" }],
			queueable,
		},
	},
});

const call = (name: string, text = "a secret note", id = 3) =>
	JSON.stringify({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: { text } } });

const rpc = (method: string, id = 1, params: object = {}) => JSON.stringify({ jsonrpc: "2.0", id, method, params });
const notification = (method: string) => JSON.stringify({ jsonrpc: "2.0", method });

async function keyPair() {
	const pair = (await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"])) as CryptoKeyPair;
	const raw = (await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer;
	return { privateKey: pair.privateKey, publicKey: toBase64(new Uint8Array(raw)) };
}

type Stored = { frame: { queued_at: number }; grantId: string };

const stored = () =>
	runInDurableObject(hubStub(), async (_, state) => [...(await state.storage.list<Stored>({ prefix: "queue:" })).values()]);

/** A paired app with a catalog, and its host gone offline. */
async function offlineApp(queueable?: string[]) {
	await clearStorage("queue");
	const key = await keyPair();
	const host = await connectHost(undefined, key.publicKey);
	const app = await pair(host, "Queue App");
	host.send({ type: "offline_catalog", client_id: app.client_id, catalog: catalog(queueable) });
	await expect
		.poll(() => runInDurableObject(hubStub(), (_, state) => state.storage.get(`catalog:${app.client_id}`)))
		.toBeTruthy();
	host.ws.close();
	return { ...app, key };
}

describe("offline answers", () => {
	it("answers from the app's catalog while the host is offline", async () => {
		const app = await offlineApp();
		const init = await mcp(app.access_token, "/mcp", { body: rpc("initialize", 1, { protocolVersion: "2025-03-26" }) });
		expect(init.status).toBe(200);
		expect(await init.json()).toMatchObject({ id: 1, result: { protocolVersion: "2025-03-26", serverInfo: { name: "porchlight" } } });

		const list = await mcp(app.access_token);
		expect(await list.json()).toMatchObject({ id: 1, result: { tools: [{ name: "notes__add" }, { name: "notes__read" }] } });

		const initialized = await mcp(app.access_token, "/mcp", { body: notification("notifications/initialized") });
		expect(initialized.status).toBe(202);
		// Paths the catalog doesn't cover, and apps without one, get the plain offline error.
		expect((await mcp(app.access_token, "/mcp/other")).status).toBe(503);
		const host = await connectHost();
		const other = await pair(host, "No Catalog");
		host.ws.close();
		expect((await mcp(other.access_token)).status).toBe(503);
	});

	it("offers its own protocol version to clients asking for another", async () => {
		const app = await offlineApp();
		const init = await mcp(app.access_token, "/mcp", { body: rpc("initialize", 1, { protocolVersion: "1999-01-01" }) });
		expect(await init.json()).toMatchObject({ result: { protocolVersion: "2025-06-18" } });
	});

	it("answers batches, empty lists, ping, and errors", async () => {
		const app = await offlineApp();
		const batch = await mcp(app.access_token, "/mcp", {
			body: `[${rpc("ping", 1)},${rpc("prompts/list", 2)},${rpc("resources/list", 3)},${rpc("resources/templates/list", 4)},${rpc("completion/complete", 5)},${notification("notifications/cancelled")}]`,
		});
		expect(await batch.json()).toEqual([
			{ jsonrpc: "2.0", id: 1, result: {} },
			{ jsonrpc: "2.0", id: 2, result: { prompts: [] } },
			{ jsonrpc: "2.0", id: 3, result: { resources: [] } },
			{ jsonrpc: "2.0", id: 4, result: { resourceTemplates: [] } },
			{ jsonrpc: "2.0", id: 5, error: { code: -32001, message: "The Mac running Porchlight is offline" } },
		]);
		const garbled = await mcp(app.access_token, "/mcp", { body: "{not json" });
		expect(garbled.status).toBe(400);
		expect(await garbled.json()).toMatchObject({ error: { code: -32700 } });
		expect((await mcp(app.access_token, "/mcp", { method: "GET", body: null })).status).toBe(405);
	});
});

describe("offline queue", () => {
	it("saves calls to queueable tools, sealed, and delivers them when the host is back", async () => {
		const app = await offlineApp();
		const saved = await (await mcp(app.access_token, "/mcp", { body: call("notes__add") })).json();
		expect(saved).toMatchObject({ id: 3, result: { isError: false } });
		expect(JSON.stringify(saved)).toContain("saved this request");

		const refused = await (await mcp(app.access_token, "/mcp", { body: call("notes__read") })).json();
		expect(refused).toMatchObject({ id: 3, result: { isError: true } });

		const items = await stored();
		expect(items).toHaveLength(1);
		expect(JSON.stringify(items)).not.toContain("a secret note");

		const host = await connectHost(undefined, app.key.publicKey);
		const queued = await host.next("queued");
		expect(queued).toMatchObject({ client_id: app.client_id, client_name: "Queue App", path: "/mcp" });
		const body = JSON.parse(dec.decode(await open(app.key.privateKey, fromBase64(queued.sealed), queued.id)));
		expect(body).toMatchObject({ method: "tools/call", params: { name: "notes__add", arguments: { text: "a secret note" } } });

		host.send({ type: "queued_done", id: queued.id });
		await expect.poll(async () => (await stored()).length).toBe(0);
	});

	it("delivers oldest first, and again until the host says it's done", async () => {
		const app = await offlineApp();
		await mcp(app.access_token, "/mcp", { body: call("notes__add", "first") });
		await mcp(app.access_token, "/mcp", { body: call("notes__add", "second") });

		const first = await connectHost(undefined, app.key.publicKey);
		const a = await first.next("queued");
		const b = await first.next("queued");
		expect(a.queued_at).toBeLessThanOrEqual(b.queued_at);
		expect(dec.decode(await open(app.key.privateKey, fromBase64(a.sealed), a.id))).toContain("first");
		first.send({ type: "queued_done", id: a.id });
		await expect.poll(async () => (await stored()).length).toBe(1);
		first.ws.close();

		const second = await connectHost(undefined, app.key.publicKey);
		expect((await second.next("queued")).id).toBe(b.id);
		second.send({ type: "queued_done", id: b.id });
		await expect.poll(async () => (await stored()).length).toBe(0);
	});

	it("drops what an app queued when it's revoked", async () => {
		const app = await offlineApp();
		await mcp(app.access_token, "/mcp", { body: call("notes__add") });
		expect(await stored()).toHaveLength(1);
		const host = await connectHost(undefined, app.key.publicKey);
		await host.next("queued");
		host.send({ type: "revoke_client", grant_id: app.grantId });
		await expect.poll(async () => (await stored()).length).toBe(0);
	});

	it("refuses to save without the host's key, or past the limit", async () => {
		const app = await offlineApp();
		await runInDurableObject(hubStub(), async (_, state) => {
			for (let i = 0; i < MAX_QUEUED; i++) await state.storage.put(`queueid:filler${i}`, `queue:filler${i}`);
		});
		const full = await (await mcp(app.access_token, "/mcp", { body: call("notes__add") })).json();
		expect(full).toMatchObject({ result: { isError: true } });

		await clearStorage("queue");
		const keyless = await (await mcp(app.access_token, "/mcp", { body: call("notes__add") })).json();
		expect(keyless).toMatchObject({ result: { isError: true } });
		expect(await stored()).toHaveLength(0);
	});

	it("forgets requests after a week", async () => {
		const app = await offlineApp();
		await mcp(app.access_token, "/mcp", { body: call("notes__add") });
		await runInDurableObject(hubStub(), async (_, state) => {
			for (const [key, item] of await state.storage.list<Stored>({ prefix: "queue:" })) {
				await state.storage.put(key, { ...item, frame: { ...item.frame, queued_at: Date.now() - QUEUE_TTL_MS - 1 } });
			}
		});
		expect(await runDurableObjectAlarm(hubStub())).toBe(true);
		expect(await stored()).toHaveLength(0);
	});
});

describe("sealing", () => {
	const vectorKey = (usage: "private" | "public") => {
		const { d, ...publicPart } = vector.private_key;
		return crypto.subtle.importKey(
			"jwk",
			{ kty: "EC", crv: "P-256", ...(usage === "private" ? { d, ...publicPart } : publicPart) },
			{ name: "ECDH", namedCurve: "P-256" },
			true,
			usage === "private" ? ["deriveBits"] : [],
		);
	};

	it("opens the shared vector, as the Mac does", async () => {
		const opened = await open(await vectorKey("private"), fromBase64(vector.sealed), vector.id);
		expect(dec.decode(opened)).toBe(vector.plaintext);
	});

	it("seals to the vector's key so its private half opens it, bound to the id", async () => {
		const recipient = new Uint8Array((await crypto.subtle.exportKey("raw", await vectorKey("public"))) as ArrayBuffer);
		const sealed = await seal(recipient, enc.encode("hello"), "id-1");
		expect(sealed.length).toBe(65 + 12 + 5 + 16);
		expect(dec.decode(await open(await vectorKey("private"), sealed, "id-1"))).toBe("hello");
		await expect(open(await vectorKey("private"), sealed, "id-2")).rejects.toThrow();
	});
});
