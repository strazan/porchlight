import {
	AuthorizationError,
	CimdFetchError,
	getOAuthApi,
	type OAuthHelpers,
	type OAuthProviderOptions,
} from "@cloudflare/workers-oauth-provider";
import { errorPage, landingPage, pairingPage } from "./consent";
import type { PairingInfo } from "./protocol";

/** Everything is granted by the one person who owns this relay. */
export const OWNER = "owner";

export function hub(env: Env) {
	return env.HUB.get(env.HUB.idFromName("default"));
}

/** Props stored with each grant, available on every request it authorizes. */
export interface GrantProps {
	clientName: string;
}

/**
 * OAuth for one relay origin. The protected resource is `<origin>/mcp`, which by path
 * prefix also covers the per-server endpoints `/mcp/<name>`.
 */
export function providerOptions(origin: string): OAuthProviderOptions<Env> {
	return {
		apiRoute: "/mcp",
		apiHandler: { fetch: forwardToHost as ExportedHandlerFetchHandler<Env> },
		defaultHandler: { fetch: (request, env) => handleDefault(request, env, origin) },
		authorizeEndpoint: "/authorize",
		tokenEndpoint: "/oauth/token",
		clientRegistrationEndpoint: "/oauth/register",
		clientIdMetadataDocumentEnabled: true,
		resourceMetadata: {
			resource: `${origin}/mcp`,
			authorization_servers: [origin],
			resource_name: "Porchlight",
		},
	};
}

export function oauthApi(origin: string, env: Env): OAuthHelpers {
	return getOAuthApi(providerOptions(origin), env);
}

/** An authorized MCP request: pass it to the host, saying which client sent it. */
async function forwardToHost(
	request: Request,
	env: Env,
	ctx: ExecutionContext & { props?: GrantProps; auth?: { clientId?: string } },
): Promise<Response> {
	const headers = new Headers(request.headers);
	for (const name of [...headers.keys()]) {
		if (name.startsWith("porchlight-")) headers.delete(name);
	}
	headers.set("porchlight-client-id", encodeURIComponent(ctx.auth?.clientId ?? ""));
	headers.set("porchlight-client-name", encodeURIComponent(ctx.props?.clientName ?? ""));
	return hub(env).fetch(new Request(request, { headers }));
}

async function handleDefault(request: Request, env: Env, origin: string): Promise<Response> {
	const { pathname, searchParams } = new URL(request.url);
	try {
		if (pathname === "/authorize" && request.method === "GET") return await showAuthorize(request, env, origin);
		if (pathname === "/authorize" && request.method === "POST") return await submitAuthorize(request, env, origin);
		if (pathname === "/authorize/status") {
			const state = await hub(env).pairingStatus(searchParams.get("id") ?? "");
			return Response.json({ state }, { headers: { "cache-control": "no-store" } });
		}
		if (pathname === "/") return html(landingPage(origin));
	} catch (error) {
		if (error instanceof AuthorizationError && error.redirectTo) return Response.redirect(error.redirectTo, 302);
		if (error instanceof AuthorizationError) return html(errorPage(error.description ?? "This request is not valid."), 400);
		if (error instanceof CimdFetchError) return html(errorPage("This app could not be verified."), 400);
		throw error;
	}
	return new Response("Not found", { status: 404 });
}

/** The consent page: shows a code and waits for the owner to approve on their Mac. */
async function showAuthorize(request: Request, env: Env, origin: string): Promise<Response> {
	const oauth = oauthApi(origin, env);
	const authRequest = await oauth.parseAuthRequest(request);
	const details = await oauth.describeConsent(authRequest);
	const consent = await oauth.beginConsent(authRequest);
	const info: PairingInfo = {
		client_id: authRequest.clientId,
		client_name: details.clientName,
		client_domain: details.clientDomain,
		redirect_host: details.redirectHost,
		loopback: details.redirectIsLoopback,
	};
	const pairing = await hub(env).startPairing(info, await sha256(consent.handle));
	consent.headers.set("content-type", "text/html; charset=utf-8");
	return new Response(pairingPage(info, consent.handle, pairing), { headers: consent.headers });
}

/** The page posts here once the Mac has decided (or the user cancelled). */
async function submitAuthorize(request: Request, env: Env, origin: string): Promise<Response> {
	const oauth = oauthApi(origin, env);
	const form = await request.formData();
	const handle = String(form.get("handle") ?? "");
	if (form.get("decision") !== "approve") {
		const denied = await oauth.denyConsent(request, handle);
		return new Response(null, { status: 302, headers: denied.headers });
	}
	// The approval must be for this very consent page, not just any pairing.
	const pairing = await hub(env).consumePairing(String(form.get("pairing") ?? ""), await sha256(handle));
	if (!pairing) return html(errorPage("This connection was not approved on your Mac."), 403);

	const approved = await oauth.approveConsent(request, handle);
	const { redirectTo } = await oauth.completeAuthorization({
		request: approved.request,
		userId: OWNER,
		metadata: pairing,
		scope: approved.request.scope,
		props: { clientName: pairing.client_name } satisfies GrantProps,
		// One app can connect several times, e.g. Claude with a connector per server. Clients
		// that identify by a metadata document share one client ID across all of those, so
		// replacing earlier grants would silently log the other connectors out.
		revokeExistingGrants: false,
	});
	// KV listings lag new writes, so tell the hub about this grant directly.
	await hub(env).clientsChanged({
		grant_id: grantIdFromRedirect(redirectTo),
		client_id: pairing.client_id,
		client_name: pairing.client_name,
		client_domain: pairing.client_domain,
		created_at: Math.floor(Date.now() / 1000),
	});
	approved.headers.set("location", redirectTo);
	return new Response(null, { status: 302, headers: approved.headers });
}

/** Authorization codes are `userId:grantId:secret`; "" if that ever changes. */
function grantIdFromRedirect(redirectTo: string): string {
	const parts = new URL(redirectTo).searchParams.get("code")?.split(":") ?? [];
	return parts.length === 3 ? parts[1]! : "";
}

function html(body: string, status = 200): Response {
	return new Response(body, {
		status,
		headers: { "content-type": "text/html; charset=utf-8", "content-security-policy": "frame-ancestors 'none'" },
	});
}

async function sha256(value: string): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
	return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
