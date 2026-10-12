// Carries HTTP requests to the host over its WebSocket, multiplexed by request id, and
// streams the responses back. Nothing here reads the requests themselves.

import { concat, fromBase64, toBase64 } from "./bytes";
import { hostOffline } from "./offline";
import type { HeaderList, HostToRelay, RelayToHost } from "./protocol";

export const MAX_REQUEST_BODY = 8 * 1024 * 1024;
const START_TIMEOUT_MS = 60_000;

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

interface Pending {
	ws: WebSocket;
	grantId: string;
	started: boolean;
	start(status: number, headers: Headers): void;
	writer: WritableStreamDefaultWriter<Uint8Array>;
	timer: ReturnType<typeof setTimeout>;
}

type ResponseFrame = Extract<HostToRelay, { type: "res_start" | "res_chunk" | "res_end" }>;

/**
 * Requests in flight. In memory only: a request in flight keeps the Durable Object awake, so
 * nothing here needs to survive hibernation.
 */
export class Tunnel {
	private pending = new Map<string, Pending>();

	/** Sends a request to the host; resolves with its response as soon as that starts. */
	forward(ws: WebSocket, request: Request, body: Uint8Array, grantId: string): Promise<Response> {
		const url = new URL(request.url);
		const headers: HeaderList = [];
		for (const [name, value] of request.headers) {
			if (!STRIP_REQUEST.has(name) && !name.startsWith("cf-")) headers.push([name, value]);
		}
		const id = crypto.randomUUID();
		const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();

		return new Promise<Response>((resolve) => {
			const timer = setTimeout(() => {
				// Resolve first: finish() would otherwise answer with its generic 502.
				resolve(new Response("Porchlight on the Mac did not respond", { status: 504 }));
				this.finish(id, "timeout");
			}, START_TIMEOUT_MS);

			this.pending.set(id, {
				ws,
				grantId,
				started: false,
				writer: writable.getWriter(),
				timer,
				start: (status, headers) => resolve(new Response(NULL_BODY_STATUS.has(status) ? null : readable, { status, headers })),
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
				resolve(hostOffline(body));
				this.finish(id, "send failed");
			}
		});
	}

	/** A response frame from the host. */
	receive(frame: ResponseFrame): void {
		const p = this.pending.get(frame.id);
		if (!p) return;
		switch (frame.type) {
			case "res_start": {
				if (p.started) return;
				p.started = true;
				clearTimeout(p.timer);
				const status = responseStatus(frame.status);
				p.start(status, responseHeaders(frame.headers));
				if (NULL_BODY_STATUS.has(status)) this.finish(frame.id);
				return;
			}
			case "res_chunk": {
				if (!p.started) return;
				let data: Uint8Array;
				try {
					data = fromBase64(frame.data_b64);
				} catch {
					return this.cancel(frame.id, "bad chunk");
				}
				// Not awaited: the write only settles once the client reads. A rejection
				// means the client went away.
				p.writer.write(data).catch(() => this.cancel(frame.id));
				return;
			}
			case "res_end":
				return this.finish(frame.id);
		}
	}

	/** Ends every request carried by `ws`. */
	hostGone(ws: WebSocket, reason: string): void {
		for (const [id, p] of this.pending) if (p.ws === ws) this.finish(id, reason);
	}

	/** Ends every request a revoked grant has in flight. */
	cancelGrant(grantId: string): void {
		for (const [id, p] of this.pending) if (p.grantId === grantId) this.cancel(id, "revoked");
	}

	/** Ends a request here and tells the host to stop working on it. */
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

	/** Closes out a request. With an error before the response started, answers 502. */
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
export async function readBody(request: Request, limit = MAX_REQUEST_BODY): Promise<Uint8Array | null> {
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
	return concat(...chunks);
}

// The host passes on what its servers answered: drop what a Response can't carry.

function responseStatus(status: number): number {
	return status >= 200 && status <= 599 ? status : 502;
}

function responseHeaders(list: HeaderList): Headers {
	const headers = new Headers();
	for (const [name, value] of list) {
		if (STRIP_RESPONSE.has(name.toLowerCase())) continue;
		try {
			headers.append(name, value);
		} catch {
			// invalid header name or value
		}
	}
	return headers;
}
