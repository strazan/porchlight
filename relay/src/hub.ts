import { DurableObject } from "cloudflare:workers";
import type { Pairing } from "./consent";
import { OWNER, oauthApi } from "./oauth";
import { answerOffline } from "./offline";
import {
	type Catalog,
	type ClientSummary,
	type HeaderList,
	type PairingInfo,
	type QueuedFrame,
	type RelayToHost,
	PING,
	PONG,
	fromBase64,
	parseHostFrame,
	toBase64,
} from "./protocol";
import { seal } from "./seal";

const START_TIMEOUT_MS = 60_000;
// As long as the consent page's handle stays valid.
const PAIRING_TTL_MS = 10 * 60_000;
// KV listings can miss writes (new or revoked grants) for up to a minute; bridge longer.
const KV_LAG_MS = 5 * 60_000;
// Revoking deletes a grant's tokens by listing them, which can miss one issued in the
// last minute. Refuse revoked grants here for longer than an access token lives (1 h).
const REVOKED_KEEP_MS = 2 * 3600_000;
// Anyone can open the consent page, so cap how many prompts can wait on the Mac.
export const MAX_PAIRINGS = 5;
const MAX_REQUEST_BODY = 8 * 1024 * 1024;
// Requests saved while the host is offline: how long they keep, how many, how big.
export const QUEUE_TTL_MS = 7 * 24 * 3600_000;
export const MAX_QUEUED = 100;
const MAX_QUEUED_BODY = 256 * 1024;

// Headers that describe this hop, or credentials meant for the relay, never the host.
const STRIP_REQUEST = new Set([
	"authorization",
	"connection",
	"content-length",
	"host",
	"keep-alive",
	"porchlight-grant-id",
	"proxy-authorization",
	"te",
	"trailer",
	"transfer-encoding",
	"upgrade",
	"x-real-ip",
]);
const STRIP_RESPONSE = new Set(["connection", "content-length", "keep-alive", "transfer-encoding", "upgrade"]);
const NULL_BODY_STATUS = new Set([101, 204, 205, 304]);

interface PairingRecord extends PairingInfo {
	code: string;
	/** SHA-256 of the consent page's handle: the approval only completes that page. */
	handleHash: string;
	state: "pending" | "approved" | "denied";
	expiresAt: number;
}

export type PairingState = PairingRecord["state"] | "expired" | "offline";

/** Stored under `queue:<13-digit ms>-<id>`, so listing returns them oldest first. */
interface QueuedItem extends QueuedFrame {
	/** So revoking the app drops what it queued. */
	grant_id: string;
}

interface Pending {
	ws: WebSocket;
	grantId: string;
	started: boolean;
	start(status: number, headers: Headers): void;
	writer: WritableStreamDefaultWriter<Uint8Array>;
	timer: ReturnType<typeof setTimeout>;
}

/**
 * One Hub per relay. Holds the host's WebSocket (hibernatable) and tunnels HTTP
 * requests over it, multiplexed by request id.
 */
export class Hub extends DurableObject<Env> {
	// In-memory only: a request in flight keeps the object awake, so nothing here
	// needs to survive hibernation.
	private pending = new Map<string, Pending>();

	constructor(ctx: DurableObjectState, env: Env) {
		super(ctx, env);
		ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(PING, PONG));
	}

	override async fetch(request: Request): Promise<Response> {
		const url = new URL(request.url);
		if (url.pathname === "/agent") return this.acceptHost(url.origin);
		return this.forward(request);
	}

	private async acceptHost(origin: string): Promise<Response> {
		for (const old of this.ctx.getWebSockets()) old.close(4000, "replaced");
		// OAuth helpers need the public origin; the host's connection is where we learn it.
		await this.ctx.storage.put("origin", origin);
		const { 0: client, 1: server } = new WebSocketPair();
		this.ctx.acceptWebSocket(server);
		// Pairings started while the host was away still need an answer.
		for (const [key, record] of await this.ctx.storage.list<PairingRecord>({ prefix: "pair:" })) {
			if (record.state === "pending" && record.expiresAt > Date.now()) {
				this.sendPairRequest(server, key.slice("pair:".length), record);
			}
		}
		// And requests saved while it was away, oldest first. Each stays until the host
		// says it's done, so one interrupted here comes again next time.
		for (const item of (await this.ctx.storage.list<QueuedItem>({ prefix: "queue:" })).values()) {
			if (item.queued_at + QUEUE_TTL_MS > Date.now()) this.sendQueued(server, item);
		}
		return new Response(null, { status: 101, webSocket: client });
	}

	// MARK: Pairing (called by the Worker's /authorize handlers)

	async startPairing(info: PairingInfo, handleHash: string): Promise<Pairing> {
		const ws = this.host();
		if (!ws) return { offline: true };
		const now = Date.now();
		const waiting = [...(await this.ctx.storage.list<PairingRecord>({ prefix: "pair:" })).values()];
		if (waiting.filter((r) => r.expiresAt > now).length >= MAX_PAIRINGS) return { busy: true };
		const id = crypto.randomUUID();
		const code = String(crypto.getRandomValues(new Uint32Array(1))[0]! % 1_000_000).padStart(6, "0");
		const record: PairingRecord = { ...info, code, handleHash, state: "pending", expiresAt: now + PAIRING_TTL_MS };
		await this.ctx.storage.put(`pair:${id}`, record);
		await this.scheduleCleanup(record.expiresAt);
		this.sendPairRequest(ws, id, record);
		return { id, code };
	}

	async pairingStatus(id: string): Promise<PairingState> {
		const record = await this.ctx.storage.get<PairingRecord>(`pair:${id}`);
		if (!record || record.expiresAt <= Date.now()) return "expired";
		if (record.state === "pending" && !this.host()) return "offline";
		return record.state;
	}

	/** Completes an approved pairing, once, for the consent page it was started from. */
	async consumePairing(id: string, handleHash: string): Promise<PairingInfo | null> {
		const record = await this.ctx.storage.get<PairingRecord>(`pair:${id}`);
		if (!record || record.state !== "approved" || record.handleHash !== handleHash || record.expiresAt <= Date.now()) {
			return null;
		}
		await this.ctx.storage.delete(`pair:${id}`);
		const { client_id, client_name, client_domain, redirect_host, loopback } = record;
		return { client_id, client_name, client_domain, redirect_host, loopback };
	}

	/**
	 * Tells the host its list of clients changed. `added` is a grant just issued: KV lists
	 * can take a minute to include it, so it's remembered here until they do.
	 */
	async clientsChanged(added?: ClientSummary): Promise<void> {
		if (added) await this.ctx.storage.put(`recent:${added.grant_id || added.client_id}`, { ...added, recorded: Date.now() });
		const ws = this.host();
		if (ws) await this.sendClients(ws);
	}

	private sendPairRequest(ws: WebSocket, id: string, record: PairingRecord): void {
		const { code, client_id, client_name, client_domain, redirect_host, loopback } = record;
		this.send(ws, { type: "pair_request", id, code, client_id, client_name, client_domain, redirect_host, loopback });
	}

	private async decidePairing(id: string, allow: boolean): Promise<void> {
		const key = `pair:${id}`;
		const record = await this.ctx.storage.get<PairingRecord>(key);
		if (!record || record.state !== "pending") return;
		await this.ctx.storage.put(key, { ...record, state: allow ? "approved" : "denied" });
	}

	// MARK: Clients

	private async sendClients(ws: WebSocket): Promise<void> {
		const oauth = await this.oauth();
		if (!oauth) return;
		const items: ClientSummary[] = [];
		const now = Date.now();
		const revoked = new Set<string>();
		for (const [key, at] of await this.ctx.storage.list<number>({ prefix: "revoked:" })) {
			if (now - at < REVOKED_KEEP_MS) revoked.add(key.slice("revoked:".length));
			else await this.ctx.storage.delete(key);
		}
		let cursor: string | undefined;
		do {
			const page = await oauth.listUserGrants(OWNER, { cursor });
			for (const grant of page.items) {
				if (revoked.has(grant.id)) continue; // revoked; KV hasn't caught up
				items.push({
					grant_id: grant.id,
					client_id: grant.clientId,
					client_name: grant.metadata?.client_name ?? grant.clientId,
					client_domain: grant.metadata?.client_domain,
					created_at: grant.createdAt,
				});
			}
			cursor = page.cursor;
		} while (cursor);
		// Grants issued moments ago, which KV may not list yet.
		for (const [key, recent] of await this.ctx.storage.list<ClientSummary & { recorded: number }>({ prefix: "recent:" })) {
			const listed = items.some((item) =>
				recent.grant_id ? item.grant_id === recent.grant_id : item.client_id === recent.client_id,
			);
			if (listed || revoked.has(recent.grant_id) || now - recent.recorded >= KV_LAG_MS) {
				await this.ctx.storage.delete(key);
			} else {
				const { recorded: _, ...summary } = recent;
				items.push(summary);
			}
		}
		this.send(ws, { type: "clients", items });
	}

	private async revokeClient(ws: WebSocket, grantId: string): Promise<void> {
		const oauth = await this.oauth();
		if (!oauth) return;
		await this.ctx.storage.put(`revoked:${grantId}`, Date.now());
		for (const [id, p] of this.pending) if (p.grantId === grantId) this.cancel(id, "revoked");
		await oauth.revokeGrant(grantId, OWNER);
		for (const [key, item] of await this.ctx.storage.list<QueuedItem>({ prefix: "queue:" })) {
			if (item.grant_id === grantId) await this.ctx.storage.delete(key);
		}
		await this.sendClients(ws);
	}

	// MARK: Offline queue

	/** Answers from the app's catalog when there is one; otherwise a plain "offline" error. */
	private async offline(request: Request, body: Uint8Array): Promise<Response> {
		const clientID = decodeURIComponent(request.headers.get("porchlight-client-id") ?? "");
		const catalog = clientID ? await this.ctx.storage.get<Catalog>(`catalog:${clientID}`) : undefined;
		if (catalog) {
			const path = new URL(request.url).pathname;
			const answered = await answerOffline(request.method, path, body, catalog, (message) =>
				this.enqueue(request, path, message),
			);
			if (answered) return answered;
		}
		return offline(body);
	}

	private async enqueue(request: Request, path: string, message: Record<string, unknown>): Promise<string | null> {
		const key = await this.ctx.storage.get<string>("queuekey");
		if (!key) return null;
		const plaintext = new TextEncoder().encode(JSON.stringify(message));
		if (plaintext.length > MAX_QUEUED_BODY) return null;
		if ((await this.ctx.storage.list({ prefix: "queue:" })).size >= MAX_QUEUED) return null;

		const id = crypto.randomUUID();
		const now = Date.now();
		const header = (name: string) => decodeURIComponent(request.headers.get(name) ?? "");
		const item: QueuedItem = {
			id,
			grant_id: header("porchlight-grant-id"),
			client_id: header("porchlight-client-id"),
			client_name: header("porchlight-client-name"),
			path,
			queued_at: now,
			sealed: toBase64(await seal(fromBase64(key), plaintext, id)),
		};
		await this.ctx.storage.put(`queue:${String(now).padStart(13, "0")}-${id}`, item);
		await this.scheduleCleanup(now + QUEUE_TTL_MS);
		// The host may have come back while this was being saved.
		const ws = this.host();
		if (ws) this.sendQueued(ws, item);
		return id;
	}

	private sendQueued(ws: WebSocket, item: QueuedItem): void {
		const { grant_id: _, ...frame } = item;
		this.send(ws, { type: "queued", ...frame });
	}

	private async queuedDone(id: string): Promise<void> {
		for (const [key, item] of await this.ctx.storage.list<QueuedItem>({ prefix: "queue:" })) {
			if (item.id === id) await this.ctx.storage.delete(key);
		}
	}

	private async scheduleCleanup(at: number): Promise<void> {
		const current = await this.ctx.storage.getAlarm();
		if (current === null || current > at) await this.ctx.storage.setAlarm(at);
	}

	/** Drops expired queued requests and pairings, then waits for the next to expire. */
	override async alarm(): Promise<void> {
		const now = Date.now();
		let next: number | undefined;
		for (const [key, item] of await this.ctx.storage.list<QueuedItem>({ prefix: "queue:" })) {
			const expires = item.queued_at + QUEUE_TTL_MS;
			if (expires <= now) await this.ctx.storage.delete(key);
			else next = Math.min(next ?? expires, expires);
		}
		for (const [key, record] of await this.ctx.storage.list<PairingRecord>({ prefix: "pair:" })) {
			if (record.expiresAt <= now) await this.ctx.storage.delete(key);
			else next = Math.min(next ?? record.expiresAt, record.expiresAt);
		}
		if (next !== undefined) await this.ctx.storage.setAlarm(next);
	}

	private async oauth() {
		const origin = await this.ctx.storage.get<string>("origin");
		return origin ? oauthApi(origin, this.env) : undefined;
	}

	private send(ws: WebSocket, frame: RelayToHost): void {
		try {
			ws.send(JSON.stringify(frame));
		} catch {
			// host gone; it gets current state when it reconnects
		}
	}

	private host(): WebSocket | undefined {
		return this.ctx.getWebSockets().find((ws) => ws.readyState === WebSocket.OPEN);
	}

	private async forward(request: Request): Promise<Response> {
		const grantId = decodeURIComponent(request.headers.get("porchlight-grant-id") ?? "");
		if (grantId && (await this.ctx.storage.get(`revoked:${grantId}`)) !== undefined) {
			return new Response("This connection was revoked", {
				status: 401,
				headers: { "www-authenticate": 'Bearer error="invalid_token"' },
			});
		}
		const body = await readBody(request, MAX_REQUEST_BODY);
		if (!body) return new Response("Request body too large", { status: 413 });
		const ws = this.host();
		if (!ws) return this.offline(request, body);

		const url = new URL(request.url);
		const headers: HeaderList = [];
		for (const [name, value] of request.headers) {
			if (!STRIP_REQUEST.has(name) && !name.startsWith("cf-")) headers.push([name, value]);
		}

		const id = crypto.randomUUID();
		const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
		const writer = writable.getWriter();

		return new Promise<Response>((resolve) => {
			const timer = setTimeout(() => {
				// Resolve first: finish() would otherwise answer with its generic 502.
				resolve(new Response("Porchlight host did not respond", { status: 504 }));
				this.finish(id, "timeout");
			}, START_TIMEOUT_MS);

			this.pending.set(id, {
				ws,
				grantId,
				started: false,
				writer,
				timer,
				start: (status, headers) => {
					resolve(new Response(NULL_BODY_STATUS.has(status) ? null : readable, { status, headers }));
				},
			});

			const frame: RelayToHost = {
				type: "req",
				id,
				method: request.method,
				path: url.pathname + url.search,
				headers,
				body_b64: toBase64(body),
			};
			try {
				ws.send(JSON.stringify(frame));
			} catch {
				resolve(offline(body));
				this.finish(id, "send failed");
			}
		});
	}

	override async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
		const frame = parseHostFrame(raw);
		if (!frame) return;
		switch (frame.type) {
			case "pair_decision":
				return this.decidePairing(frame.id, frame.allow);
			case "list_clients":
				return this.sendClients(ws);
			case "revoke_client":
				return this.revokeClient(ws, frame.grant_id);
			case "hello":
				ws.serializeAttachment({ proto: frame.proto, app_version: frame.app_version });
				// The key queued requests are sealed to; hosts without one get no queue.
				if (frame.queue_key && decodesTo(frame.queue_key, 65)) {
					await this.ctx.storage.put("queuekey", frame.queue_key);
				}
				return;
			case "offline_catalog":
				if (frame.catalog) await this.ctx.storage.put(`catalog:${frame.client_id}`, frame.catalog);
				else await this.ctx.storage.delete(`catalog:${frame.client_id}`);
				return;
			case "queued_done":
				return this.queuedDone(frame.id);
			case "res_start": {
				const p = this.pending.get(frame.id);
				if (!p || p.started) return;
				// The host passes on what its servers answered: drop what a Response can't carry.
				const headers = new Headers();
				for (const [name, value] of frame.headers) {
					if (STRIP_RESPONSE.has(name.toLowerCase())) continue;
					try {
						headers.append(name, value);
					} catch {
						// invalid header name or value
					}
				}
				const status = frame.status >= 200 && frame.status <= 599 && frame.status !== 101 ? frame.status : 502;
				p.started = true;
				clearTimeout(p.timer);
				p.start(status, headers);
				if (NULL_BODY_STATUS.has(status)) this.finish(frame.id);
				return;
			}
			case "res_chunk": {
				const p = this.pending.get(frame.id);
				if (!p?.started) return;
				// Not awaited: the write only settles once the client reads. A rejection
				// means the client went away.
				let data: Uint8Array;
				try {
					data = fromBase64(frame.data_b64);
				} catch {
					return this.cancel(frame.id);
				}
				p.writer.write(data).catch(() => this.cancel(frame.id));
				return;
			}
			case "res_end":
				this.finish(frame.id);
				return;
		}
	}

	override webSocketClose(ws: WebSocket, code: number, reason: string): void {
		for (const [id, p] of this.pending) if (p.ws === ws) this.finish(id, "host disconnected");
		try {
			ws.close(code, reason);
		} catch {
			// already closed
		}
	}

	override webSocketError(ws: WebSocket): void {
		for (const [id, p] of this.pending) if (p.ws === ws) this.finish(id, "host error");
	}

	private cancel(id: string, error?: string): void {
		const p = this.pending.get(id);
		if (!p) return;
		this.finish(id, error);
		try {
			p.ws.send(JSON.stringify({ type: "cancel", id } satisfies RelayToHost));
		} catch {
			// host gone; nothing to tell
		}
	}

	/** Close out a request. With an error before the response started, answer 502. */
	private finish(id: string, error?: string): void {
		const p = this.pending.get(id);
		if (!p) return;
		this.pending.delete(id);
		clearTimeout(p.timer);
		if (error === undefined) {
			p.writer.close().catch(() => {});
		} else if (p.started) {
			// End the stream rather than abort it: clients see the same truncated
			// response either way, and an abort surfaces as an uncaught exception.
			console.warn(`request ${id} ended early: ${error}`);
			p.writer.close().catch(() => {});
		} else {
			p.start(502, new Headers({ "content-type": "text/plain" }));
			p.writer.close().catch(() => {});
		}
	}
}

/** The request body, or null if it's longer than `limit` (checked before reading it all). */
async function readBody(request: Request, limit: number): Promise<Uint8Array | null> {
	if (Number(request.headers.get("content-length") ?? 0) > limit) return null;
	if (!request.body) return new Uint8Array();
	const chunks: Uint8Array[] = [];
	let length = 0;
	const reader = request.body.getReader();
	for (;;) {
		const { done, value } = await reader.read();
		if (done) break;
		length += value.length;
		if (length > limit) {
			await reader.cancel().catch(() => {});
			return null;
		}
		chunks.push(value);
	}
	const body = new Uint8Array(length);
	let offset = 0;
	for (const chunk of chunks) {
		body.set(chunk, offset);
		offset += chunk.length;
	}
	return body;
}

function decodesTo(b64: string, length: number): boolean {
	try {
		return fromBase64(b64).length === length;
	} catch {
		return false;
	}
}

/** 503 with a JSON-RPC error, so MCP clients show something readable. */
function offline(body: Uint8Array): Response {
	let id: unknown = null;
	try {
		const msg = JSON.parse(new TextDecoder().decode(body));
		if (msg && typeof msg === "object" && "id" in msg) id = msg.id;
	} catch {
		// not JSON
	}
	return Response.json(
		{ jsonrpc: "2.0", id, error: { code: -32001, message: "Porchlight host is offline" } },
		{ status: 503 },
	);
}
