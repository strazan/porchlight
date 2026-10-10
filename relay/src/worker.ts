import { PROTOCOL_VERSION } from "./protocol";

export { Hub } from "./hub";

export default {
	async fetch(request, env): Promise<Response> {
		const { pathname } = new URL(request.url);

		if (pathname === "/health") return Response.json({ ok: true, proto: PROTOCOL_VERSION });

		if (pathname === "/agent") {
			if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
				return new Response("Expected WebSocket upgrade", { status: 426 });
			}
			if (!env.AGENT_SECRET) return new Response("AGENT_SECRET is not configured", { status: 500 });
			const token = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
			if (!(await secretsEqual(token, env.AGENT_SECRET))) return new Response("Unauthorized", { status: 401 });
			if (request.headers.get("porchlight-protocol") !== String(PROTOCOL_VERSION)) {
				return new Response(`Unsupported protocol; relay speaks ${PROTOCOL_VERSION}`, { status: 426 });
			}
			return hub(env).fetch(request);
		}

		if (pathname === "/mcp" || pathname.startsWith("/s/")) {
			// Stopgap until OAuth (M1): an optional shared key, as ?key= or a bearer token.
			if (env.CLIENT_KEY) {
				const url = new URL(request.url);
				const key = url.searchParams.get("key") ?? request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
				if (!(await secretsEqual(key, env.CLIENT_KEY))) return new Response("Unauthorized", { status: 401 });
				url.searchParams.delete("key");
				request = new Request(url, request);
			}
			return hub(env).fetch(request);
		}

		return new Response("Not found", { status: 404 });
	},
} satisfies ExportedHandler<Env>;

function hub(env: Env) {
	return env.HUB.get(env.HUB.idFromName("default"));
}

/** Constant-time comparison; hashing first makes the lengths equal. */
async function secretsEqual(a: string, b: string): Promise<boolean> {
	const enc = new TextEncoder();
	const [ha, hb] = await Promise.all([
		crypto.subtle.digest("SHA-256", enc.encode(a)),
		crypto.subtle.digest("SHA-256", enc.encode(b)),
	]);
	return crypto.subtle.timingSafeEqual(ha, hb);
}
