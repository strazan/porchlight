import { OAuthProvider } from "@cloudflare/workers-oauth-provider";
import { hub, providerOptions } from "./oauth";
import { PROTOCOL_VERSION } from "./protocol";

export { Hub } from "./hub";

// The relay's public origin is only known per request (each user deploys their own).
const providers = new Map<string, OAuthProvider<Env>>();

function provider(origin: string): OAuthProvider<Env> {
	let existing = providers.get(origin);
	if (!existing) {
		existing = new OAuthProvider(providerOptions(origin));
		providers.set(origin, existing);
	}
	return existing;
}

export default {
	async fetch(request, env, ctx): Promise<Response> {
		const url = new URL(request.url);

		if (url.pathname === "/health") return Response.json({ ok: true, proto: PROTOCOL_VERSION });

		if (url.pathname === "/host") {
			if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
				return new Response("Expected WebSocket upgrade", { status: 426 });
			}
			if (!env.HOST_SECRET) return new Response("HOST_SECRET is not configured", { status: 500 });
			const token = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
			if (!(await secretsEqual(token, env.HOST_SECRET))) return new Response("Unauthorized", { status: 401 });
			if (request.headers.get("porchlight-protocol") !== String(PROTOCOL_VERSION)) {
				return new Response(`Unsupported protocol; relay speaks ${PROTOCOL_VERSION}`, { status: 426 });
			}
			return hub(env).fetch(request);
		}

		// OAuth endpoints, the consent page, and /mcp (which requires a token).
		return provider(url.origin).fetch(request, env, ctx);
	},
} satisfies ExportedHandler<Env>;

/** Constant-time comparison; hashing first makes the lengths equal. */
async function secretsEqual(a: string, b: string): Promise<boolean> {
	const enc = new TextEncoder();
	const [ha, hb] = await Promise.all([
		crypto.subtle.digest("SHA-256", enc.encode(a)),
		crypto.subtle.digest("SHA-256", enc.encode(b)),
	]);
	return crypto.subtle.timingSafeEqual(ha, hb);
}
