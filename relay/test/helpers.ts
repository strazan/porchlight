import { SELF, env, runInDurableObject } from "cloudflare:test";
import { expect } from "vitest";
import { fromBase64, toBase64 } from "../src/bytes";
import type { HostToRelay, RelayToHost } from "../src/protocol";
import { hub } from "../src/stub";

export const enc = new TextEncoder();
export const dec = new TextDecoder();
export const ORIGIN = "https://relay.test";
export const RESOURCE = `${ORIGIN}/mcp`;
const REDIRECT_URI = "https://client.test/callback";

export type ReqFrame = Extract<RelayToHost, { type: "req" }>;
type Send = (f: HostToRelay) => void;

export const hubStub = () => hub(env);

/** Deletes the Hub's storage under `prefix` (tests share one Hub). */
export function clearStorage(prefix: string) {
	return runInDurableObject(hubStub(), async (_, state) => {
		await state.storage.delete([...(await state.storage.list({ prefix })).keys()]);
	});
}

const openHosts = new Set<WebSocket>();

/** Closes every host a test left connected, so the next test starts with none (see setup.ts). */
export function closeHosts() {
	for (const ws of openHosts) {
		try {
			ws.close();
		} catch {
			// already closed
		}
	}
	openHosts.clear();
}

/** A fake Porchlight host connected to the relay. */
export async function connectHost(onRequest: (req: ReqFrame, send: Send) => void = () => {}, queueKey?: string) {
	const res = await SELF.fetch(`${ORIGIN}/host`, {
		headers: { upgrade: "websocket", authorization: "Bearer test-secret", "porchlight-protocol": "1" },
	});
	expect(res.status).toBe(101);
	const ws = res.webSocket!;
	ws.accept();
	openHosts.add(ws);
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
	/** The client list once it includes `clientId`. */
	const clientsWith = (clientId: string) => next("clients", (f) => f.items.some((item) => item.client_id === clientId));
	return { ws, send, next, pairRequest, clientsWith };
}

export type Host = Awaited<ReturnType<typeof connectHost>>;

export function respond(send: Send, id: string, status: number, body: string, headers: [string, string][] = []) {
	send({ type: "res_start", id, status, headers });
	if (body) send({ type: "res_chunk", id, data_b64: toBase64(enc.encode(body)) });
	send({ type: "res_end", id });
}

export const rpc = (id: number) => JSON.stringify({ jsonrpc: "2.0", id, method: "tools/list" });

/** Echoes each request's body back. */
export const echo = (req: ReqFrame, send: Send) =>
	respond(send, req.id, 200, dec.decode(fromBase64(req.body_b64)), [["content-type", "application/json"]]);

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
export async function startAuthorization(clientName = "Test Client", existingClient?: string) {
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

export async function pairingState(id: string): Promise<string> {
	const res = await SELF.fetch(`${ORIGIN}/authorize/status?id=${encodeURIComponent(id)}`);
	return ((await res.json()) as { state: string }).state;
}

/** What the consent page's script posts once the Mac has decided. */
export function submit(started: Started, decision: "approve" | "deny") {
	return SELF.fetch(`${ORIGIN}/authorize`, {
		method: "POST",
		redirect: "manual",
		headers: { cookie: started.cookie, "content-type": "application/x-www-form-urlencoded", origin: ORIGIN },
		body: new URLSearchParams({ handle: started.handle, pairing: started.pairing, decision }),
	});
}

/** The whole flow, approved on the (fake) Mac. Returns the client's tokens and its grant. */
export async function pair(host: Host, clientName = "Test Client", existingClient?: string) {
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
	const grantId = callback.searchParams.get("code")!.split(":")[1]!;
	return { ...tokens, client_id: started.client_id, grantId, request };
}

export function mcp(token: string, path = "/mcp", init: RequestInit = {}) {
	const headers = new Headers(init.headers);
	headers.set("authorization", `Bearer ${token}`);
	return SELF.fetch(`${ORIGIN}${path}`, { method: "POST", body: rpc(1), ...init, headers });
}
