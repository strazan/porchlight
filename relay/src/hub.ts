import { DurableObject } from "cloudflare:workers";
import {
	type HeaderList,
	type RelayToHost,
	PING,
	PONG,
	fromBase64,
	parseHostFrame,
	toBase64,
} from "./protocol";

const START_TIMEOUT_MS = 60_000;
const MAX_REQUEST_BODY = 8 * 1024 * 1024;

// Headers that describe this hop, or credentials meant for the relay, never the host.
const STRIP_REQUEST = new Set([
	"authorization",
	"connection",
	"content-length",
	"host",
	"keep-alive",
	"proxy-authorization",
	"te",
	"trailer",
	"transfer-encoding",
	"upgrade",
	"x-real-ip",
]);
const STRIP_RESPONSE = new Set(["connection", "content-length", "keep-alive", "transfer-encoding", "upgrade"]);
const NULL_BODY_STATUS = new Set([101, 204, 205, 304]);

interface Pending {
	ws: WebSocket;
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
		if (new URL(request.url).pathname === "/agent") return this.acceptHost();
		return this.forward(request);
	}

	private acceptHost(): Response {
		for (const old of this.ctx.getWebSockets()) old.close(4000, "replaced");
		const { 0: client, 1: server } = new WebSocketPair();
		this.ctx.acceptWebSocket(server);
		return new Response(null, { status: 101, webSocket: client });
	}

	private host(): WebSocket | undefined {
		return this.ctx.getWebSockets().find((ws) => ws.readyState === WebSocket.OPEN);
	}

	private async forward(request: Request): Promise<Response> {
		const body = new Uint8Array(await request.arrayBuffer());
		const ws = this.host();
		if (!ws) return offline(body);
		if (body.length > MAX_REQUEST_BODY) return new Response("Request body too large", { status: 413 });

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

	override webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): void {
		const frame = parseHostFrame(raw);
		if (!frame) return;
		switch (frame.type) {
			case "hello":
				ws.serializeAttachment({ proto: frame.proto, app_version: frame.app_version });
				return;
			case "res_start": {
				const p = this.pending.get(frame.id);
				if (!p || p.started) return;
				p.started = true;
				clearTimeout(p.timer);
				const headers = new Headers();
				for (const [name, value] of frame.headers) {
					if (!STRIP_RESPONSE.has(name.toLowerCase())) headers.append(name, value);
				}
				p.start(frame.status, headers);
				if (NULL_BODY_STATUS.has(frame.status)) this.finish(frame.id);
				return;
			}
			case "res_chunk": {
				const p = this.pending.get(frame.id);
				if (!p?.started) return;
				// Not awaited: the write only settles once the client reads. A rejection
				// means the client went away.
				p.writer.write(fromBase64(frame.data_b64)).catch(() => this.cancel(frame.id));
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

	private cancel(id: string): void {
		const p = this.pending.get(id);
		if (!p) return;
		this.finish(id);
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
