import { SELF } from "cloudflare:test";
import { expect, it } from "vitest";
import { ORIGIN, RESOURCE, closeHosts, connectHost, echo, mcp, pair, respond, type ReqFrame } from "./helpers";

it("binds borrowed access to its grant and strips spoofed loan headers", async () => {
	let seen: ReqFrame | undefined;
	const host = await connectHost((req, send) => { seen = req; echo(req, send); });
	const owner = await pair(host, "Claude");
	await host.clientsWith(owner.client_id);
	const guest = await pair(host, "Claude", owner.client_id, true);
	expect(guest.request.supports_lending).toBe(true);
	expect((await mcp(guest.access_token, "/mcp", { headers: { "porchlight-loan-id": "someone-else" } })).status).toBe(200);
	expect(new Map(seen!.headers).get("porchlight-loan-id")).toBe(guest.request.id);
	expect((await mcp(owner.access_token, "/mcp", { headers: { "porchlight-loan-id": guest.request.id } })).status).toBe(200);
	expect(new Map(seen!.headers).has("porchlight-loan-id")).toBe(false);
	host.send({ type: "list_clients" });
	const list = await host.next("clients", f => f.items.some(i => i.grant_id === guest.grantId));
	expect(list.items.find(i => i.grant_id === guest.grantId)?.loan_id).toBe(guest.request.id);
	host.send({ type: "revoke_client", grant_id: guest.grantId });
	await host.next("clients", f => !f.items.some(i => i.grant_id === guest.grantId));
	expect((await mcp(guest.access_token)).status).toBe(401);
	expect((await mcp(owner.access_token)).status).toBe(200);
});

it("never serves the owner's offline catalog to a borrower", async () => {
	const host = await connectHost(echo);
	const owner = await pair(host);
	const guest = await pair(host, "Test Client", owner.client_id, true);
	host.send({ type: "offline_catalog", client_id: owner.client_id, catalog: {
		protocol_versions: ["2025-06-18"], paths: { "/mcp": { initialize: {}, tools: [{ name: "private" }], queueable: [] } },
	} });
	// A round trip ensures the catalog message was processed before disconnecting.
	host.send({ type: "list_clients" });
	await host.next("clients", f => f.items.some(i => i.grant_id === guest.grantId));
	closeHosts();
	await expect.poll(async () => (await mcp(owner.access_token)).text()).toContain("private");
	expect(await (await mcp(guest.access_token)).text()).not.toContain("private");
});

it("refuses borrowed access on hosts without lending support", async () => {
	const host = await connectHost(echo);
	const guest = await pair(host, "Guest", undefined, true);
	await connectHost((req, send) => respond(send, req.id, 200, "should not reach old host"), undefined, false);
	expect((await mcp(guest.access_token)).status).toBe(403);
});

it("preserves the loan restriction when OAuth tokens refresh", async () => {
	let seen: ReqFrame | undefined;
	const host = await connectHost((req, send) => { seen = req; echo(req, send); });
	const guest = await pair(host, "Guest", undefined, true);
	const refreshed = await SELF.fetch(`${ORIGIN}/oauth/token`, {
		method: "POST",
		headers: { "content-type": "application/x-www-form-urlencoded" },
		body: new URLSearchParams({
			grant_type: "refresh_token", refresh_token: guest.refresh_token!,
			client_id: guest.client_id, resource: RESOURCE,
		}),
	});
	expect(refreshed.status).toBe(200);
	const tokens = await refreshed.json() as { access_token: string };
	expect((await mcp(tokens.access_token)).status).toBe(200);
	expect(new Map(seen!.headers).get("porchlight-loan-id")).toBe(guest.request.id);
});
