import { SELF, env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import worker from "../src/worker";
import { type HostToRelay, type RelayToHost, fromBase64, toBase64 } from "../src/protocol";

const enc = new TextEncoder();
const dec = new TextDecoder();

type ReqFrame = Extract<RelayToHost, { type: "req" }>;

/** A fake Porchlight host connected to the relay. */
async function connectHost(onRequest: (req: ReqFrame, send: (f: HostToRelay) => void) => void) {
	const res = await SELF.fetch("https://relay.test/agent", {
		headers: { upgrade: "websocket", authorization: "Bearer test-secret", "porchlight-protocol": "1" },
	});
	expect(res.status).toBe(101);
	const ws = res.webSocket!;
	ws.accept();
	const send = (f: HostToRelay) => ws.send(JSON.stringify(f));
	const frames: RelayToHost[] = [];
	ws.addEventListener("message", (e) => {
		const frame = JSON.parse(e.data as string) as RelayToHost;
		frames.push(frame);
		if (frame.type === "req") onRequest(frame, send);
	});
	send({ type: "hello", proto: 1, app_version: "test" });
	return { ws, frames, send };
}

function respond(send: (f: HostToRelay) => void, id: string, status: number, body: string, headers: [string, string][] = []) {
	send({ type: "res_start", id, status, headers });
	if (body) send({ type: "res_chunk", id, data_b64: toBase64(enc.encode(body)) });
	send({ type: "res_end", id });
}

const rpc = (id: number) => JSON.stringify({ jsonrpc: "2.0", id, method: "tools/list" });

describe("relay", () => {
	it("serves health", async () => {
		const res = await SELF.fetch("https://relay.test/health");
		expect(await res.json()).toEqual({ ok: true, proto: 1 });
	});

	it("answers with a JSON-RPC error when no host is connected", async () => {
		const res = await SELF.fetch("https://relay.test/mcp", { method: "POST", body: rpc(7) });
		expect(res.status).toBe(503);
		expect(await res.json()).toMatchObject({ id: 7, error: { code: -32001 } });
	});

	it("rejects hosts with a bad secret or protocol", async () => {
		const bad = await SELF.fetch("https://relay.test/agent", {
			headers: { upgrade: "websocket", authorization: "Bearer nope", "porchlight-protocol": "1" },
		});
		expect(bad.status).toBe(401);
		const old = await SELF.fetch("https://relay.test/agent", {
			headers: { upgrade: "websocket", authorization: "Bearer test-secret", "porchlight-protocol": "0" },
		});
		expect(old.status).toBe(426);
	});

	it("tunnels a request and response", async () => {
		let seen: ReqFrame | undefined;
		const host = await connectHost((req, send) => {
			seen = req;
			respond(send, req.id, 200, dec.decode(fromBase64(req.body_b64)), [["content-type", "application/json"], ["mcp-session-id", "abc"]]);
		});
		const res = await SELF.fetch("https://relay.test/s/files/mcp?x=1", {
			method: "POST",
			headers: { authorization: "Bearer client-token", "content-type": "application/json", "mcp-protocol-version": "2025-06-18" },
			body: rpc(1),
		});
		expect(res.status).toBe(200);
		expect(res.headers.get("mcp-session-id")).toBe("abc");
		expect(await res.text()).toBe(rpc(1));
		expect(seen?.path).toBe("/s/files/mcp?x=1");
		const names = seen!.headers.map(([n]) => n);
		expect(names).toContain("mcp-protocol-version");
		expect(names).not.toContain("authorization");
		host.ws.close();
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
		const res = await SELF.fetch("https://relay.test/mcp", { method: "POST", body: rpc(2) });
		const reader = res.body!.getReader();
		expect(dec.decode((await reader.read()).value)).toBe("data: one\n\n");
		release();
		expect(dec.decode((await reader.read()).value)).toBe("data: two\n\n");
		expect((await reader.read()).done).toBe(true);
		host.ws.close();
	});

	it("passes through null-body statuses", async () => {
		const host = await connectHost((req, send) => respond(send, req.id, 204, ""));
		const res = await SELF.fetch("https://relay.test/mcp", { method: "DELETE" });
		expect(res.status).toBe(204);
		host.ws.close();
	});

	it("returns 502 when the host disconnects before responding", async () => {
		const host = await connectHost(() => host.ws.close(1011, "crash"));
		const res = await SELF.fetch("https://relay.test/mcp", { method: "POST", body: rpc(3) });
		expect(res.status).toBe(502);
	});

	it("ends the stream when the host disconnects mid-response", async () => {
		const host = await connectHost((req, send) => {
			send({ type: "res_start", id: req.id, status: 200, headers: [["content-type", "text/event-stream"]] });
			send({ type: "res_chunk", id: req.id, data_b64: toBase64(enc.encode(": keepalive\n\n")) });
		});
		const res = await SELF.fetch("https://relay.test/mcp", { method: "POST", body: rpc(5) });
		const reader = res.body!.getReader();
		expect(dec.decode((await reader.read()).value)).toBe(": keepalive\n\n");
		host.ws.close(1011, "crash");
		expect((await reader.read()).done).toBe(true);
	});

	it("requires the client key when one is configured", async () => {
		let seenPath: string | undefined;
		const host = await connectHost((req, send) => {
			seenPath = req.path;
			respond(send, req.id, 200, "ok");
		});
		const keyed = { ...env, CLIENT_KEY: "k3y" };
		const call = (url: string, headers: Record<string, string> = {}) =>
			worker.fetch(new Request(url, { method: "POST", body: rpc(6), headers }), keyed);

		expect((await call("https://relay.test/mcp")).status).toBe(401);
		expect((await call("https://relay.test/mcp?key=wrong")).status).toBe(401);
		expect((await call("https://relay.test/mcp", { authorization: "Bearer k3y" })).status).toBe(200);
		const ok = await call("https://relay.test/mcp?key=k3y&x=1");
		expect(await ok.text()).toBe("ok");
		expect(seenPath).toBe("/mcp?x=1");
		host.ws.close();
	});

	it("replaces an existing host connection", async () => {
		const first = await connectHost(() => {});
		const closed = new Promise<number>((r) => first.ws.addEventListener("close", (e) => r(e.code)));
		const second = await connectHost((req, send) => respond(send, req.id, 200, "second"));
		expect(await closed).toBe(4000);
		const res = await SELF.fetch("https://relay.test/mcp", { method: "POST", body: rpc(4) });
		expect(await res.text()).toBe("second");
		second.ws.close();
	});
});
