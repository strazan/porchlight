// What both end-to-end scripts need: an OAuth client for the official MCP SDK, and the
// consent page as the user's browser would go through it (the host approves on the "Mac").
import { UnauthorizedError } from "@modelcontextprotocol/sdk/client/auth.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

export const RELAY = process.env.RELAY ?? "http://localhost:8787";
export const log = (...a) => console.log("•", ...a);
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function check(ok, message) {
	if (!ok) throw new Error(`FAILED: ${message}`);
	log("ok:", message);
}

/** The SDK's OAuth client provider, keeping everything in memory. */
export class Provider {
	authorizations = 0;

	constructor(name) {
		this.name = name;
	}

	get redirectUrl() {
		return "http://localhost:9999/callback";
	}

	get clientMetadata() {
		return {
			client_name: this.name,
			redirect_uris: [this.redirectUrl],
			grant_types: ["authorization_code", "refresh_token"],
			response_types: ["code"],
			token_endpoint_auth_method: "none",
		};
	}

	clientInformation() {
		return this.client;
	}

	saveClientInformation(info) {
		this.client = info;
	}

	tokens() {
		return this.savedTokens;
	}

	saveTokens(tokens) {
		this.savedTokens = tokens;
	}

	redirectToAuthorization(url) {
		this.authorizations++;
		this.authUrl = url;
	}

	saveCodeVerifier(verifier) {
		this.verifier = verifier;
	}

	codeVerifier() {
		return this.verifier;
	}
}

/** Goes through the consent page and returns the authorization code once the host approves. */
async function consent(authUrl) {
	const page = await fetch(authUrl, { redirect: "manual" });
	const cookie = page.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
	const html = await page.text();
	const field = (name) => html.match(new RegExp(`name="${name}" value="([^"]*)"`))?.[1] ?? "";
	const pairing = field("pairing");
	if (!pairing) throw new Error("The consent page says Porchlight is offline. Is the host running and connected?");
	log("consent page shows code", html.match(/class="code">([^<]+)</)?.[1]);
	for (;;) {
		const { state } = await (await fetch(`${RELAY}/authorize/status?id=${pairing}`)).json();
		if (state === "approved") break;
		if (state !== "pending") throw new Error(`pairing ${state}`);
		await sleep(300);
	}
	const res = await fetch(`${RELAY}/authorize`, {
		method: "POST",
		redirect: "manual",
		headers: { cookie, "content-type": "application/x-www-form-urlencoded", origin: RELAY },
		body: new URLSearchParams({ handle: field("handle"), pairing, decision: "approve" }),
	});
	return new URL(res.headers.get("location")).searchParams.get("code");
}

/** An SDK client connected to `path` on the relay, signing in first if it needs to. */
export async function connect(path, provider) {
	const url = new URL(path, RELAY);
	const client = new Client({ name: "porchlight-e2e", version: "1" });
	try {
		await client.connect(new StreamableHTTPClientTransport(url, { authProvider: provider }));
	} catch (error) {
		if (!(error instanceof UnauthorizedError)) throw error;
		await new StreamableHTTPClientTransport(url, { authProvider: provider }).finishAuth(await consent(provider.authUrl));
		await client.connect(new StreamableHTTPClientTransport(url, { authProvider: provider }));
	}
	return client;
}
