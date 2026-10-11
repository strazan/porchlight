import { SELF, env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { MAX_QUEUED, QUEUE_TTL_MS } from "../src/hub";
import { type Catalog, type HostToRelay, type RelayToHost, fromBase64, toBase64 } from "../src/protocol";
import { open } from "../src/seal";
import vector from "../../protocol/vectors/queue.json";

const enc = new TextEncoder();
const dec = new TextDecoder();
const ORIGIN = "https://relay.test";
const RESOURCE = `${ORIGIN}/mcp`;
const REDIRECT_URI = "https://client.test/callback";

type ReqFrame = Extract<RelayToHost, { type: "req" }>;
type Send = (f: HostToRelay) => void;

/** A fake Porchlight host connected to the relay. */
async function connectHost(onRequest: (req: ReqFrame, send: Send) => void = () => {}, queueKey?: string) {
	const res = await SELF.fetch(`${ORIGIN}/agent`, {
		headers: { upgrade: "websocket", authorization: "Bearer test-secret", "porchlight-protocol": "1" },
	});
	expect(res.status).toBe(101);
	const ws = res.webSocket!;
	ws.accept();
	const send: Send = (f) => ws.send(JSON.stringify(f));
	const frames: RelayToHost[] = [];
	const waiters: { matches: (f: RelayToHost) => boolean; resolve: (f: RelayToHost) => void }[] = [];
	ws.addEventListener("message", (e) => {
		const frame = JSON.parse(e.data as string) as RelayToHost;
		frames.push(frame);
		if (frame.type === "req") onRequest(frame, send);
		const waiter = waiters.find((w) => w.matches(frame));
		if (waiter) {
			waiters.splice(waiters.indexOf(waiter), 1);
			waiter.resolve(frame);
		}
	});
	send({ type: "hello", proto: 1, app_version: "test", queue_key: queueKey });
	/** The next frame of `type` matching `where` (or one already received and not yet taken). */
	function next<T extends RelayToHost["type"]>(
		type: T,
		where: (frame: Extract<RelayToHost, { type: T }>) => boolean = () => true,
	): Promise<Extract<RelayToHost, { type: T }>> {
		const matches = (f: RelayToHost): f is Extract<RelayToHost, { type: T }> =>
			f.type === type && where(f as Extract<RelayToHost, { type: T }>);
		const index = frames.findIndex(matches);
		if (index >= 0) return Promise.resolve(frames.splice(index, 1)[0] as Extract<RelayToHost, { type: T }>);
		return new Promise((resolve) =>
			waiters.push({
				matches,
				resolve: (f) => {
					frames.splice(frames.indexOf(f), 1);
					resolve(f as Extract<RelayToHost, { type: T }>);
				},
			}),
		);
	}
	/** The pair_request for one consent page (earlier tests may leave others pending). */
	const pairRequest = (pairingId: string) => next("pair_request", (f) => f.id === pairingId);
	return { ws, send, next, pairRequest };
}

type Host = Awaited<ReturnType<typeof connectHost>>;

function respond(send: Send, id: string, status: number, body: string, headers: [string, string][] = []) {
	send({ type: "res_start", id, status, headers });
	if (body) send({ type: "res_chunk", id, data_b64: toBase64(enc.encode(body)) });
	send({ type: "res_end", id });
}

const rpc = (id: number) => JSON.stringify({ jsonrpc: "2.0", id, method: "tools/list" });

function base64url(bytes: ArrayBuffer | Uint8Array): string {
	return toBase64(new Uint8Array(bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function register(clientName: string): Promise<string> {
	const registration = await SELF.fetch(`${ORIGIN}/oauth/register`, {
		method: "POST",
		headers: { "content-type": "application/json" },
		body: JSON.stringify({
			client_name: clientName,
			redirect_uris: [REDIRECT_URI],
			token_endpoint_auth_method: "none",
			grant_types: ["authorization_code", "refresh_token"],
			response_types: ["code"],
		}),
	});
	expect(registration.status).toBe(201);
	return ((await registration.json()) as { client_id: string }).client_id;
}

/** Starts an authorization like an MCP client: DCR (unless reusing a client), then /authorize with PKCE. */
async function startAuthorization(clientName = "Test Client", existingClient?: string) {
	const client_id = existingClient ?? (await register(clientName));

	const verifier = base64url(crypto.getRandomValues(new Uint8Array(32)));
	const challenge = base64url(await crypto.subtle.digest("SHA-256", enc.encode(verifier)));
	const query = new URLSearchParams({
		response_type: "code",
		client_id,
		redirect_uri: REDIRECT_URI,
		code_challenge: challenge,
		code_challenge_method: "S256",
		state: "state-123",
		resource: RESOURCE,
	});
	const page = await SELF.fetch(`${ORIGIN}/authorize?${query}`, { redirect: "manual" });
	expect(page.status).toBe(200);
	const cookie = page.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
	const html = await page.text();
	const field = (name: string) => html.match(new RegExp(`name="${name}" value="([^"]*)"`))?.[1] ?? "";
	return { client_id, verifier, cookie, html, handle: field("handle"), pairing: field("pairing") };
}

type Started = Awaited<ReturnType<typeof startAuthorization>>;

async function pairingState(id: string): Promise<string> {
	const res = await SELF.fetch(`${ORIGIN}/authorize/status?id=${encodeURIComponent(id)}`);
	return ((await res.json()) as { state: string }).state;
}

/** What the consent page's script posts once the Mac has decided. */
function submit(started: Started, decision: "approve" | "deny") {
	return SELF.fetch(`${ORIGIN}/authorize`, {
		method: "POST",
		redirect: "manual",
		headers: { cookie: started.cookie, "content-type": "application/x-www-form-urlencoded", origin: ORIGIN },
		body: new URLSearchParams({ handle: started.handle, pairing: started.pairing, decision }),
	});
}

/** The whole flow, approved on the (fake) Mac. Returns the client's tokens. */
async function pair(host: Host, clientName = "Test Client", existingClient?: string) {
	const started = await startAuthorization(clientName, existingClient);
	const request = await host.pairRequest(started.pairing);
	host.send({ type: "pair_decision", id: request.id, allow: true });
	await expect.poll(() => pairingState(started.pairing)).toBe("approved");

	const approved = await submit(started, "approve");
	expect(approved.status).toBe(302);
	const callback = new URL(approved.headers.get("location")!);
	expect(callback.origin + callback.pathname).toBe(REDIRECT_URI);
	expect(callback.searchParams.get("state")).toBe("state-123");

	const tokenResponse = await SELF.fetch(`${ORIGIN}/oauth/token`, {
		method: "POST",
		headers: { "content-type": "application/x-www-form-urlencoded" },
		body: new URLSearchParams({
			grant_type: "authorization_code",
			code: callback.searchParams.get("code")!,
			redirect_uri: REDIRECT_URI,
			client_id: started.client_id,
			code_verifier: started.verifier,
			resource: RESOURCE,
		}),
	});
	expect(tokenResponse.status).toBe(200);
	const tokens = (await tokenResponse.json()) as { access_token: string; refresh_token?: string };
	return { ...tokens, client_id: started.client_id, request };
}

function mcp(token: string, path = "/mcp", init: RequestInit = {}) {
	const headers = new Headers(init.headers);
	headers.set("authorization", `Bearer ${token}`);
	return SELF.fetch(`${ORIGIN}${path}`, { method: "POST", body: rpc(1), ...init, headers });
}

describe("relay basics", () => {
	it("serves health and a landing page", async () => {
		expect(await (await SELF.fetch(`${ORIGIN}/health`)).json()).toEqual({ ok: true, proto: 1 });
		expect(await (await SELF.fetch(`${ORIGIN}/`)).text()).toContain(`${ORIGIN}/mcp`);
	});

	it("rejects hosts with a bad secret or protocol", async () => {
		const bad = await SELF.fetch(`${ORIGIN}/agent`, {
			headers: { upgrade: "websocket", authorization: "Bearer nope", "porchlight-protocol": "1" },
		});
		expect(bad.status).toBe(401);
		const old = await SELF.fetch(`${ORIGIN}/agent`, {
			headers: { upgrade: "websocket", authorization: "Bearer test-secret", "porchlight-protocol": "0" },
		});
		expect(old.status).toBe(426);
	});
});

describe("oauth", () => {
	it("challenges unauthenticated MCP requests and publishes discovery metadata", async () => {
		const res = await SELF.fetch(`${ORIGIN}/mcp`, { method: "POST", body: rpc(1) });
		expect(res.status).toBe(401);
		const challenge = res.headers.get("www-authenticate") ?? "";
		const metadataURL = challenge.match(/resource_metadata="([^"]+)"/)?.[1];
		expect(metadataURL).toBeDefined();

		const resource = (await (await SELF.fetch(metadataURL!)).json()) as { resource: string; authorization_servers: string[] };
		expect(resource.resource).toBe(RESOURCE);
		expect(resource.authorization_servers).toEqual([ORIGIN]);

		const server = (await (await SELF.fetch(`${ORIGIN}/.well-known/oauth-authorization-server`)).json()) as Record<string, unknown>;
		expect(server.issuer).toBe(ORIGIN);
		expect(server.registration_endpoint).toBe(`${ORIGIN}/oauth/register`);
		expect(server.client_id_metadata_document_supported).toBe(true);

		// Per-server endpoints sit under the same resource.
		expect((await SELF.fetch(`${ORIGIN}/mcp/files`, { method: "POST", body: rpc(1) })).status).toBe(401);
	});

	it("pairs a client approved on the Mac and tunnels its requests", async () => {
		let seen: ReqFrame | undefined;
		const host = await connectHost((req, send) => {
			seen = req;
			respond(send, req.id, 200, dec.decode(fromBase64(req.body_b64)), [["content-type", "application/json"]]);
		});
		const { access_token, request, client_id } = await pair(host, "Claude ☀️");
		const started = { client_id };
		expect(request.client_name).toBe("Claude ☀️");
		expect(request.client_id).toBe(started.client_id);
		expect(request.redirect_host).toBe("client.test");
		expect(request.code).toMatch(/^\d{6}$/);

		const res = await mcp(access_token, "/mcp/files?x=1", { headers: { "porchlight-client-name": "spoofed" } });
		expect(res.status).toBe(200);
		expect(await res.text()).toBe(rpc(1));
		expect(seen?.path).toBe("/mcp/files?x=1");
		const headers = new Map(seen!.headers);
		expect(headers.has("authorization")).toBe(false);
		expect(decodeURIComponent(headers.get("porchlight-client-name")!)).toBe("Claude ☀️");
		host.ws.close();
	});

	it("shows the same code on the page as on the Mac", async () => {
		const host = await connectHost();
		const started = await startAuthorization();
		const request = await host.pairRequest(started.pairing);
		expect(started.html).toContain(`${request.code.slice(0, 3)} ${request.code.slice(3)}`);
		host.ws.close();
	});

	it("sends the client back with access_denied when the Mac declines", async () => {
		const host = await connectHost();
		const started = await startAuthorization();
		const request = await host.pairRequest(started.pairing);
		host.send({ type: "pair_decision", id: request.id, allow: false });
		await expect.poll(() => pairingState(started.pairing)).toBe("denied");
		const denied = await submit(started, "deny");
		expect(denied.status).toBe(302);
		expect(new URL(denied.headers.get("location")!).searchParams.get("error")).toBe("access_denied");
		host.ws.close();
	});

	it("refuses to complete a pairing the Mac hasn't approved", async () => {
		const host = await connectHost();
		const started = await startAuthorization();
		await host.pairRequest(started.pairing);
		expect((await submit(started, "approve")).status).toBe(403);
		host.ws.close();
	});

	it("tells the user when Porchlight is offline", async () => {
		const started = await startAuthorization();
		expect(started.html).toContain("Porchlight isn't running");
		expect(started.pairing).toBe("");
	});

	it("re-sends pending pairings when the host reconnects", async () => {
		const first = await connectHost();
		const started = await startAuthorization();
		await first.pairRequest(started.pairing);
		first.ws.close();
		await expect.poll(() => pairingState(started.pairing)).toBe("offline");

		const second = await connectHost();
		const resent = await second.pairRequest(started.pairing);
		second.send({ type: "pair_decision", id: resent.id, allow: true });
		await expect.poll(() => pairingState(started.pairing)).toBe("approved");
		second.ws.close();
	});

	it("keeps every connection when the same app connects again", async () => {
		const host = await connectHost((req, send) => respond(send, req.id, 200, "ok"));
		const first = await pair(host, "Twice");
		const second = await pair(host, "Twice", first.client_id);
		expect(second.client_id).toBe(first.client_id);
		// Both connections (e.g. two connectors in one app) still work.
		expect((await mcp(first.access_token)).status).toBe(200);
		expect((await mcp(second.access_token)).status).toBe(200);
		host.send({ type: "list_clients" });
		const listed = await host.next("clients", (f) => f.items.filter((i) => i.client_id === first.client_id).length === 2);
		expect(new Set(listed.items.filter((i) => i.client_id === first.client_id).map((i) => i.grant_id)).size).toBe(2);
		host.ws.close();
	});

	it("lists and revokes paired clients from the host", async () => {
		const host = await connectHost((req, send) => respond(send, req.id, 200, "ok"));
		const { access_token, client_id } = await pair(host, "Revocable");
		// Clients paired by earlier tests in this file are listed too.
		const listed = await host.next("clients");
		const mine = listed.items.find((item) => item.client_id === client_id);
		expect(mine).toMatchObject({ client_name: "Revocable" });
		expect((await mcp(access_token)).status).toBe(200);

		host.send({ type: "revoke_client", grant_id: mine!.grant_id });
		const after = await host.next("clients");
		expect(after.items.map((item) => item.client_id)).not.toContain(client_id);
		expect(after.items).toHaveLength(listed.items.length - 1);
		expect((await mcp(access_token)).status).toBe(401);
		host.ws.close();
	});
});

describe("client list while KV lags", () => {
	const hubStub = () => env.HUB.get(env.HUB.idFromName("default"));

	it("lists a just-paired app once, with its grant id", async () => {
		const host = await connectHost();
		const { client_id } = await pair(host, "Fresh");
		const listed = await host.next("clients");
		const mine = listed.items.filter((item) => item.client_id === client_id);
		expect(mine).toHaveLength(1);
		expect(mine[0]!.grant_id).not.toBe("");
		host.ws.close();
	});

	it("shows an app KV doesn't list yet", async () => {
		const host = await connectHost();
		await hubStub().clientsChanged({
			grant_id: "g-lagging", client_id: "lagging-client", client_name: "Lagging", created_at: 1,
		});
		const listed = await host.next("clients", (f) => f.items.some((item) => item.client_id === "lagging-client"));
		expect(listed.items.find((item) => item.client_id === "lagging-client")?.client_name).toBe("Lagging");
		host.ws.close();
	});

	it("hides a revoked grant KV still lists", async () => {
		const host = await connectHost();
		const { client_id } = await pair(host, "Revoked");
		const listed = await host.next("clients");
		const grant = listed.items.find((item) => item.client_id === client_id)!;
		// Pretend KV still lists the grant after revocation: only the tombstone hides it.
		await runInDurableObject(hubStub(), async (_, state) => {
			await state.storage.put(`revoked:${grant.grant_id}`, Date.now());
			await state.storage.delete(`recent:${client_id}`);
		});
		host.send({ type: "list_clients" });
		const after = await host.next("clients");
		expect(after.items.map((item) => item.client_id)).not.toContain(client_id);
		host.ws.close();
	});
});

describe("tunnel", () => {
	it("answers with a JSON-RPC error when the host is offline", async () => {
		const host = await connectHost();
		const { access_token } = await pair(host);
		host.ws.close();
		const res = await mcp(access_token, "/mcp", { body: JSON.stringify({ jsonrpc: "2.0", id: 7, method: "ping" }) });
		expect(res.status).toBe(503);
		expect(await res.json()).toMatchObject({ id: 7, error: { code: -32001 } });
	});

	it("streams chunks as they arrive", async () => {
		let release!: () => void;
		const gate = new Promise<void>((r) => (release = r));
		const host = await connectHost((req, send) => {
			send({ type: "res_start", id: req.id, status: 200, headers: [["content-type", "text/event-stream"]] });
			send({ type: "res_chunk", id: req.id, data_b64: toBase64(enc.encode("data: one\n\n")) });
			gate.then(() => {
				send({ type: "res_chunk", id: req.id, data_b64: toBase64(enc.encode("data: two\n\n")) });
				send({ type: "res_end", id: req.id });
			});
		});
		const { access_token } = await pair(host);
		const reader = (await mcp(access_token)).body!.getReader();
		expect(dec.decode((await reader.read()).value)).toBe("data: one\n\n");
		release();
		expect(dec.decode((await reader.read()).value)).toBe("data: two\n\n");
		expect((await reader.read()).done).toBe(true);
		host.ws.close();
	});

	it("passes through null-body statuses", async () => {
		const host = await connectHost((req, send) => respond(send, req.id, 204, ""));
		const { access_token } = await pair(host);
		expect((await mcp(access_token, "/mcp", { method: "DELETE", body: null })).status).toBe(204);
		host.ws.close();
	});

	it("returns 502 when the host disconnects before responding", async () => {
		const host = await connectHost(() => host.ws.close(1011, "crash"));
		const { access_token } = await pair(host);
		expect((await mcp(access_token)).status).toBe(502);
	});

	it("ends the stream when the host disconnects mid-response", async () => {
		const host = await connectHost((req, send) => {
			send({ type: "res_start", id: req.id, status: 200, headers: [["content-type", "text/event-stream"]] });
			send({ type: "res_chunk", id: req.id, data_b64: toBase64(enc.encode(": keepalive\n\n")) });
		});
		const { access_token } = await pair(host);
		const reader = (await mcp(access_token)).body!.getReader();
		expect(dec.decode((await reader.read()).value)).toBe(": keepalive\n\n");
		host.ws.close(1011, "crash");
		expect((await reader.read()).done).toBe(true);
	});

	it("replaces an existing host connection", async () => {
		const first = await connectHost();
		const { access_token } = await pair(first);
		const closed = new Promise<number>((r) => first.ws.addEventListener("close", (e) => r(e.code)));
		const second = await connectHost((req, send) => respond(send, req.id, 200, "second"));
		expect(await closed).toBe(4000);
		expect(await (await mcp(access_token)).text()).toBe("second");
		second.ws.close();
	});
});

describe("offline queue", () => {
	const hubStub = () => env.HUB.get(env.HUB.idFromName("default"));
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
	const call = (name: string, text = "a secret note") =>
		JSON.stringify({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name, arguments: { text } } });

	async function keyPair() {
		const pair = (await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"])) as CryptoKeyPair;
		const raw = (await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer;
		return { privateKey: pair.privateKey, publicKey: toBase64(new Uint8Array(raw)) };
	}

	const stored = () =>
		runInDurableObject(hubStub(), async (_, state) => [...(await state.storage.list<Record<string, unknown>>({ prefix: "queue:" })).values()]);

	/** A paired app with a catalog, and its host gone offline. */
	async function offlineApp(queueable?: string[]) {
		await runInDurableObject(hubStub(), async (_, state) => {
			for (const key of (await state.storage.list({ prefix: "queue:" })).keys()) await state.storage.delete(key);
		});
		const key = await keyPair();
		const host = await connectHost(undefined, key.publicKey);
		const app = await pair(host, "Queue App");
		const listed = await host.next("clients", (f) => f.items.some((item) => item.client_id === app.client_id));
		const grantID = listed.items.find((item) => item.client_id === app.client_id)!.grant_id;
		host.send({ type: "offline_catalog", client_id: app.client_id, catalog: catalog(queueable) });
		await expect
			.poll(() => runInDurableObject(hubStub(), (_, state) => state.storage.get(`catalog:${app.client_id}`)))
			.toBeTruthy();
		host.ws.close();
		return { ...app, key, grantID };
	}

	it("answers from the app's catalog while the host is offline", async () => {
		const app = await offlineApp();
		const init = await mcp(app.access_token, "/mcp", {
			body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-03-26" } }),
		});
		expect(init.status).toBe(200);
		expect(await init.json()).toMatchObject({ id: 1, result: { protocolVersion: "2025-03-26", serverInfo: { name: "porchlight" } } });

		const list = await mcp(app.access_token);
		expect(await list.json()).toMatchObject({ id: 1, result: { tools: [{ name: "notes__add" }, { name: "notes__read" }] } });

		const notification = await mcp(app.access_token, "/mcp", {
			body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }),
		});
		expect(notification.status).toBe(202);
		// Paths the catalog doesn't cover, and apps without one, get the plain offline error.
		expect((await mcp(app.access_token, "/mcp/other")).status).toBe(503);
		const host = await connectHost();
		const other = await pair(host, "No Catalog");
		host.ws.close();
		expect((await mcp(other.access_token)).status).toBe(503);
	});

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
		host.ws.close();
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
		second.ws.close();
	});

	it("drops what an app queued when it's revoked", async () => {
		const app = await offlineApp();
		await mcp(app.access_token, "/mcp", { body: call("notes__add") });
		expect(await stored()).toHaveLength(1);
		const host = await connectHost(undefined, app.key.publicKey);
		await host.next("queued");
		host.send({ type: "revoke_client", grant_id: app.grantID });
		await expect.poll(async () => (await stored()).length).toBe(0);
		host.ws.close();
	});

	it("refuses to save without the host's key, or past the limit", async () => {
		const app = await offlineApp();
		await runInDurableObject(hubStub(), async (_, state) => {
			for (let i = 0; i < MAX_QUEUED; i++) await state.storage.put(`queue:0000000000000-filler${i}`, { id: `filler${i}`, queued_at: Date.now() });
		});
		const full = await (await mcp(app.access_token, "/mcp", { body: call("notes__add") })).json();
		expect(full).toMatchObject({ result: { isError: true } });

		await runInDurableObject(hubStub(), async (_, state) => {
			for (const key of (await state.storage.list({ prefix: "queue:" })).keys()) await state.storage.delete(key);
			await state.storage.delete("queuekey");
		});
		const keyless = await (await mcp(app.access_token, "/mcp", { body: call("notes__add") })).json();
		expect(keyless).toMatchObject({ result: { isError: true } });
		expect(await stored()).toHaveLength(0);
	});

	it("seals the way the Mac opens (shared vector)", async () => {
		const privateKey = await crypto.subtle.importKey(
			"jwk",
			{ kty: "EC", crv: "P-256", ...vector.private_key },
			{ name: "ECDH", namedCurve: "P-256" },
			false,
			["deriveBits"],
		);
		const opened = await open(privateKey, fromBase64(vector.sealed), vector.id);
		expect(dec.decode(opened)).toBe(vector.plaintext);
	});

	it("forgets requests after a week", async () => {
		const app = await offlineApp();
		await mcp(app.access_token, "/mcp", { body: call("notes__add") });
		await runInDurableObject(hubStub(), async (_, state) => {
			for (const [key, item] of await state.storage.list<{ queued_at: number }>({ prefix: "queue:" })) {
				await state.storage.put(key, { ...item, queued_at: Date.now() - QUEUE_TTL_MS - 1 });
			}
		});
		expect(await runDurableObjectAlarm(hubStub())).toBe(true);
		expect(await stored()).toHaveLength(0);
	});
});
