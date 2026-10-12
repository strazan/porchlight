import { SELF, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { MAX_PAIRINGS } from "../src/pairing";
import {
	ORIGIN,
	RESOURCE,
	type ReqFrame,
	clearStorage,
	connectHost,
	echo,
	hubStub,
	mcp,
	pair,
	pairingState,
	respond,
	rpc,
	startAuthorization,
	submit,
} from "./helpers";

describe("relay basics", () => {
	it("serves health and a landing page", async () => {
		expect(await (await SELF.fetch(`${ORIGIN}/health`)).json()).toEqual({ ok: true, proto: 1 });
		expect(await (await SELF.fetch(`${ORIGIN}/`)).text()).toContain(`${ORIGIN}/mcp`);
	});

	it("rejects hosts that aren't WebSockets, or have a bad secret or protocol", async () => {
		const plain = await SELF.fetch(`${ORIGIN}/host`, { headers: { authorization: "Bearer test-secret" } });
		expect(plain.status).toBe(426);
		const bad = await SELF.fetch(`${ORIGIN}/host`, {
			headers: { upgrade: "websocket", authorization: "Bearer nope", "porchlight-protocol": "1" },
		});
		expect(bad.status).toBe(401);
		const old = await SELF.fetch(`${ORIGIN}/host`, {
			headers: { upgrade: "websocket", authorization: "Bearer test-secret", "porchlight-protocol": "0" },
		});
		expect(old.status).toBe(426);
	});
});

describe("pairing", () => {
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

	it("pairs an app approved on the Mac and tunnels its requests", async () => {
		let seen: ReqFrame | undefined;
		const host = await connectHost((req, send) => {
			seen = req;
			echo(req, send);
		});
		const { access_token, request, client_id } = await pair(host, "Claude ☀️");
		expect(request).toMatchObject({ client_name: "Claude ☀️", client_id, redirect_host: "client.test" });
		expect(request.code).toMatch(/^\d{6}$/);

		const res = await mcp(access_token, "/mcp/files?x=1", { headers: { "porchlight-client-name": "spoofed" } });
		expect(res.status).toBe(200);
		expect(await res.text()).toBe(rpc(1));
		expect(seen?.path).toBe("/mcp/files?x=1");
		const headers = new Map(seen!.headers);
		expect(headers.has("authorization")).toBe(false);
		expect(headers.has("porchlight-grant-id")).toBe(false);
		expect(decodeURIComponent(headers.get("porchlight-client-name")!)).toBe("Claude ☀️");
		expect(decodeURIComponent(headers.get("porchlight-client-id")!)).toBe(client_id);
	});

	it("shows the same code on the page as on the Mac", async () => {
		const host = await connectHost();
		const started = await startAuthorization();
		const request = await host.pairRequest(started.pairing);
		expect(started.html).toContain(`${request.code.slice(0, 3)} ${request.code.slice(3)}`);
	});

	it("sends the app back with access_denied when the Mac declines", async () => {
		const host = await connectHost();
		const started = await startAuthorization();
		const request = await host.pairRequest(started.pairing);
		host.send({ type: "pair_decision", id: request.id, allow: false });
		await expect.poll(() => pairingState(started.pairing)).toBe("denied");
		const denied = await submit(started, "deny");
		expect(denied.status).toBe(302);
		expect(new URL(denied.headers.get("location")!).searchParams.get("error")).toBe("access_denied");
	});

	it("refuses to complete a pairing the Mac hasn't approved", async () => {
		const host = await connectHost();
		const started = await startAuthorization();
		await host.pairRequest(started.pairing);
		expect((await submit(started, "approve")).status).toBe(403);
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
	});

	it("caps how many pairings wait on the Mac, and expires them", async () => {
		await connectHost();
		await clearStorage("pair:");
		for (let i = 0; i < MAX_PAIRINGS; i++) expect((await startAuthorization()).pairing).not.toBe("");
		const refused = await startAuthorization();
		expect(refused.html).toContain("Too many requests are waiting");
		expect(refused.pairing).toBe("");

		// Each expires on its own, even on a relay that never queues anything.
		await runInDurableObject(hubStub(), async (_, state) => {
			for (const [key, record] of await state.storage.list<{ expiresAt: number }>({ prefix: "pair:" })) {
				await state.storage.put(key, { ...record, expiresAt: Date.now() - 1 });
			}
		});
		expect(await runDurableObjectAlarm(hubStub())).toBe(true);
		const left = await runInDurableObject(hubStub(), async (_, state) => (await state.storage.list({ prefix: "pair:" })).size);
		expect(left).toBe(0);
	});

	it("keeps an app's name to one plain line", async () => {
		const host = await connectHost();
		const started = await startAuthorization("Claude\nPublished by claude.ai‮​");
		const request = await host.pairRequest(started.pairing);
		expect(request.client_name).toBe("Claude Published by claude.ai");
		host.send({ type: "pair_decision", id: request.id, allow: false });
	});
});

describe("clients", () => {
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
	});

	it("lists a just-paired app once, with its grant id", async () => {
		const host = await connectHost();
		const { client_id, grantId } = await pair(host, "Fresh");
		const mine = (await host.clientsWith(client_id)).items.filter((item) => item.client_id === client_id);
		expect(mine).toEqual([expect.objectContaining({ grant_id: grantId })]);
	});

	it("shows an app KV doesn't list yet", async () => {
		const host = await connectHost();
		await hubStub().clientsChanged({ grant_id: "g-lagging", client_id: "lagging-client", client_name: "Lagging", created_at: 1 });
		const listed = await host.clientsWith("lagging-client");
		expect(listed.items.find((item) => item.client_id === "lagging-client")?.client_name).toBe("Lagging");
	});

	it("revokes a connection from the host", async () => {
		const host = await connectHost((req, send) => respond(send, req.id, 200, "ok"));
		const { access_token, client_id, grantId } = await pair(host, "Revocable");
		expect((await host.clientsWith(client_id)).items.find((item) => item.client_id === client_id)?.client_name).toBe("Revocable");
		expect((await mcp(access_token)).status).toBe(200);

		host.send({ type: "revoke_client", grant_id: grantId });
		const after = await host.next("clients", (f) => !f.items.some((item) => item.grant_id === grantId));
		expect(after.items.map((item) => item.client_id)).not.toContain(client_id);
		expect((await mcp(access_token)).status).toBe(401);
	});

	it("hides a revoked grant KV still lists", async () => {
		const host = await connectHost();
		const { client_id, grantId } = await pair(host, "Revoked");
		await host.clientsWith(client_id);
		// Pretend KV still lists the grant after revocation: only the tombstone hides it.
		await runInDurableObject(hubStub(), async (_, state) => {
			await state.storage.put(`revoked:${grantId}`, Date.now());
			await state.storage.delete(`recent:${grantId}`);
		});
		host.send({ type: "list_clients" });
		const after = await host.next("clients", (f) => !f.items.some((item) => item.grant_id === grantId));
		expect(after.items.map((item) => item.client_id)).not.toContain(client_id);
	});

	it("refuses a revoked connection even if its token survived", async () => {
		const host = await connectHost((req, send) => respond(send, req.id, 200, "ok"));
		const { access_token, grantId } = await pair(host, "Lingering");
		// Revoking lists the grant's tokens in KV, which can miss a new one: only the tombstone is left.
		await runInDurableObject(hubStub(), (_, state) => state.storage.put(`revoked:${grantId}`, Date.now()));
		expect((await mcp(access_token)).status).toBe(401);
	});

	it("ends a revoked connection's request in flight", async () => {
		let arrived!: () => void;
		const requested = new Promise<void>((resolve) => (arrived = resolve));
		const host = await connectHost(() => arrived());
		const { access_token, grantId } = await pair(host, "Streaming");
		const response = mcp(access_token);
		await requested;
		host.send({ type: "revoke_client", grant_id: grantId });
		await host.next("cancel");
		expect((await response).status).toBe(502);
	});
});
