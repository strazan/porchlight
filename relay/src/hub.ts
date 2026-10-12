import { DurableObject } from "cloudflare:workers";
import { Clients } from "./clients";
import { oauthApi } from "./oauth";
import { answerOffline, hostOffline } from "./offline";
import { type Pairing, type PairingState, Pairings } from "./pairing";
import { type ClientSummary, type PairingInfo, type RelayToHost, PING, PONG, parseHostFrame } from "./protocol";
import { OfflineQueue, QUEUE_TTL_MS, type Sender } from "./queue";
import { Tunnel, readBody } from "./tunnel";

/**
 * One Hub per relay. Holds the host's WebSocket (hibernatable), tunnels requests over it,
 * and keeps what must outlive a request: pairings, the client list, the offline queue.
 */
export class Hub extends DurableObject<Env> {
	private readonly tunnel = new Tunnel();
	private readonly pairings: Pairings;
	private readonly clients: Clients;
	private readonly queue: OfflineQueue;

	constructor(ctx: DurableObjectState, env: Env) {
		super(ctx, env);
		ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(PING, PONG));
		this.pairings = new Pairings(ctx.storage);
		// OAuth helpers need the public origin; the host's connection is where it's learned.
		this.clients = new Clients(ctx.storage, async () => {
			const origin = await ctx.storage.get<string>("origin");
			return origin ? oauthApi(origin, env) : undefined;
		});
		this.queue = new OfflineQueue(ctx.storage);
	}

	override async fetch(request: Request): Promise<Response> {
		const url = new URL(request.url);
		if (url.pathname === "/host") return this.acceptHost(url.origin);
		return this.forward(request);
	}

	private async acceptHost(origin: string): Promise<Response> {
		for (const old of this.ctx.getWebSockets()) old.close(4000, "replaced");
		await this.ctx.storage.put("origin", origin);
		const { 0: client, 1: server } = new WebSocketPair();
		this.ctx.acceptWebSocket(server);
		// Pairings started while the host was away still need an answer,
		for (const frame of await this.pairings.pending()) this.send(server, frame);
		// and requests saved while it was away, oldest first. Each stays until the host
		// says it's done, so one interrupted here comes again next time.
		for (const frame of await this.queue.waiting()) this.send(server, { type: "queued", ...frame });
		return new Response(null, { status: 101, webSocket: client });
	}

	// MARK: Called by the Worker's /authorize handlers

	async startPairing(info: PairingInfo, handleHash: string): Promise<Pairing> {
		const ws = this.host();
		if (!ws) return { offline: true };
		const started = await this.pairings.start(info, handleHash);
		if (!started) return { busy: true };
		await this.scheduleAlarm(started.expiresAt);
		this.send(ws, started.frame);
		return { id: started.frame.id, code: started.frame.code };
	}

	async pairingStatus(id: string): Promise<PairingState> {
		const state = await this.pairings.state(id);
		return state === "pending" && !this.host() ? "offline" : state;
	}

	async consumePairing(id: string, handleHash: string): Promise<PairingInfo | null> {
		return this.pairings.consume(id, handleHash);
	}

	/** Tells the host its list of clients changed; `added` is a grant just issued. */
	async clientsChanged(added?: ClientSummary): Promise<void> {
		if (added) await this.clients.remember(added);
		const ws = this.host();
		if (ws) await this.sendClients(ws);
	}

	// MARK: Requests from apps

	private async forward(request: Request): Promise<Response> {
		const grantId = decodeURIComponent(request.headers.get("porchlight-grant-id") ?? "");
		if (await this.clients.isRevoked(grantId)) {
			return new Response("This connection was revoked", {
				status: 401,
				headers: { "www-authenticate": 'Bearer error="invalid_token"' },
			});
		}
		const body = await readBody(request);
		if (!body) return new Response("Request body too large", { status: 413 });
		const ws = this.host();
		return ws ? this.tunnel.forward(ws, request, body, grantId) : this.answerOffline(request, body, grantId);
	}

	/** Answers from the app's catalog when there is one; otherwise a plain "offline" error. */
	private async answerOffline(request: Request, body: Uint8Array, grantId: string): Promise<Response> {
		const header = (name: string) => decodeURIComponent(request.headers.get(name) ?? "");
		const sender: Sender = { grantId, clientId: header("porchlight-client-id"), clientName: header("porchlight-client-name") };
		const catalog = await this.queue.catalog(sender.clientId);
		const path = new URL(request.url).pathname;
		const answered =
			catalog && (await answerOffline(request.method, path, body, catalog, (message) => this.enqueue(message, path, sender)));
		return answered || hostOffline(body);
	}

	private async enqueue(message: unknown, path: string, sender: Sender): Promise<string | null> {
		const frame = await this.queue.add(message, path, sender);
		if (!frame) return null;
		await this.scheduleAlarm(frame.queued_at + QUEUE_TTL_MS);
		// The host may have come back while this was being saved.
		const ws = this.host();
		if (ws) this.send(ws, { type: "queued", ...frame });
		return frame.id;
	}

	// MARK: The host's connection

	override async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
		const frame = parseHostFrame(raw);
		if (!frame) return;
		switch (frame.type) {
			case "hello":
				if (frame.queue_key) await this.queue.setKey(frame.queue_key);
				return;
			case "pair_decision":
				return this.pairings.decide(frame.id, frame.allow);
			case "list_clients":
				return this.sendClients(ws);
			case "revoke_client":
				return this.revoke(ws, frame.grant_id);
			case "offline_catalog":
				return this.queue.setCatalog(frame.client_id, frame.catalog);
			case "queued_done":
				return this.queue.done(frame.id);
			case "res_start":
			case "res_chunk":
			case "res_end":
				return this.tunnel.receive(frame);
		}
	}

	override webSocketClose(ws: WebSocket, code: number, reason: string): void {
		this.tunnel.hostGone(ws, "host disconnected");
		try {
			ws.close(code, reason);
		} catch {
			// already closed
		}
	}

	override webSocketError(ws: WebSocket): void {
		this.tunnel.hostGone(ws, "host error");
	}

	private async sendClients(ws: WebSocket): Promise<void> {
		const items = await this.clients.list();
		if (items) this.send(ws, { type: "clients", items });
	}

	private async revoke(ws: WebSocket, grantId: string): Promise<void> {
		await this.clients.revoke(grantId);
		this.tunnel.cancelGrant(grantId);
		await this.queue.dropGrant(grantId);
		await this.sendClients(ws);
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

	// MARK: Expiry

	/** Drops expired queued requests and pairings, then waits for the next to expire. */
	override async alarm(): Promise<void> {
		const now = Date.now();
		const next = [await this.queue.expire(now), await this.pairings.expire(now)].filter((at) => at !== undefined);
		if (next.length > 0) await this.ctx.storage.setAlarm(Math.min(...next));
	}

	private async scheduleAlarm(at: number): Promise<void> {
		const current = await this.ctx.storage.getAlarm();
		if (current === null || current > at) await this.ctx.storage.setAlarm(at);
	}
}
