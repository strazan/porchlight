import { describe, expect, it } from "vitest";
import { toBase64 } from "../src/bytes";
import { MAX_REQUEST_BODY } from "../src/tunnel";
import { connectHost, dec, enc, mcp, pair, respond } from "./helpers";

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
	});

	it("passes through null-body statuses", async () => {
		const host = await connectHost((req, send) => respond(send, req.id, 204, ""));
		const { access_token } = await pair(host);
		expect((await mcp(access_token, "/mcp", { method: "DELETE", body: null })).status).toBe(204);
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
		await connectHost((req, send) => respond(send, req.id, 200, "second"));
		expect(await closed).toBe(4000);
		expect(await (await mcp(access_token)).text()).toBe("second");
	});

	it("refuses bodies that are too large before reading them", async () => {
		const host = await connectHost((req, send) => respond(send, req.id, 200, "ok"));
		const { access_token } = await pair(host);
		const res = await mcp(access_token, "/mcp", { body: new Uint8Array(MAX_REQUEST_BODY + 1) });
		expect(res.status).toBe(413);
	});

	it("passes on only what a response can carry", async () => {
		const host = await connectHost((req, send) => {
			send({ type: "res_start", id: req.id, status: 42, headers: [["bad header", "x"], ["x-ok", "1"], ["Connection", "close"]] });
			send({ type: "res_chunk", id: req.id, data_b64: toBase64(enc.encode("hi")) });
			send({ type: "res_end", id: req.id });
		});
		const { access_token } = await pair(host);
		const res = await mcp(access_token);
		expect(res.status).toBe(502);
		expect(res.headers.get("x-ok")).toBe("1");
		expect(res.headers.get("connection")).toBeNull();
	});

	it("cancels a response whose chunk isn't base64", async () => {
		const host = await connectHost((req, send) => {
			send({ type: "res_start", id: req.id, status: 200, headers: [] });
			send({ type: "res_chunk", id: req.id, data_b64: "not base64!" });
		});
		const { access_token } = await pair(host);
		const res = await mcp(access_token);
		await host.next("cancel");
		expect(await res.text()).toBe("");
	});
});
