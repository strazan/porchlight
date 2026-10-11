// Answers MCP requests while the host is offline, from the catalog it last sent: enough
// for a client to keep seeing its tools, and to save calls to tools the owner lets queue.
// The only place the relay reads MCP; while the host is online, requests pass through as-is.

import type { Catalog, CatalogPath } from "./protocol";

/** Saves one `tools/call` for the host; resolves to its id, or null if it can't be saved. */
export type Enqueue = (message: Record<string, unknown>) => Promise<string | null>;

type Message = Record<string, unknown>;

/** Null when the catalog doesn't cover `path`; the caller then answers as before. */
export async function answerOffline(
	method: string,
	path: string,
	body: Uint8Array,
	catalog: Catalog,
	enqueue: Enqueue,
): Promise<Response | null> {
	const entry = catalog.paths[path.replace(/\/+$/, "")];
	if (!entry) return null;
	if (method !== "POST") return new Response("Method not allowed", { status: 405, headers: { allow: "POST" } });
	let parsed: unknown;
	try {
		parsed = JSON.parse(new TextDecoder().decode(body));
	} catch {
		return Response.json(rpcError(null, -32700, "Parse error"), { status: 400 });
	}
	const replies: Message[] = [];
	for (const message of Array.isArray(parsed) ? parsed : [parsed]) {
		const reply = await answer(message, entry, catalog, enqueue);
		if (reply) replies.push(reply);
	}
	if (replies.length === 0) return new Response(null, { status: 202 });
	return Response.json(Array.isArray(parsed) ? replies : replies[0]);
}

async function answer(raw: unknown, entry: CatalogPath, catalog: Catalog, enqueue: Enqueue): Promise<Message | null> {
	if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return rpcError(null, -32600, "Invalid request");
	const message = raw as Message;
	if (typeof message.method !== "string") return rpcError(message.id ?? null, -32600, "Invalid request");
	if (!("id" in message)) return null; // a notification
	const id = message.id;
	const params = (typeof message.params === "object" && message.params !== null ? message.params : {}) as Message;

	switch (message.method) {
		case "initialize": {
			const requested = params.protocolVersion;
			const version = typeof requested === "string" && catalog.protocol_versions.includes(requested)
				? requested
				: entry.initialize.protocolVersion;
			return result(id, { ...entry.initialize, protocolVersion: version });
		}
		case "ping":
			return result(id, {});
		case "tools/list":
			return result(id, { tools: entry.tools });
		case "prompts/list":
			return result(id, { prompts: [] });
		case "resources/list":
			return result(id, { resources: [] });
		case "resources/templates/list":
			return result(id, { resourceTemplates: [] });
		case "tools/call": {
			const name = typeof params.name === "string" ? params.name : "This tool";
			if (!entry.queueable.includes(name)) {
				return toolResult(id, `${name} runs on the user's Mac, which is offline right now. It can't run until the Mac is back.`, true);
			}
			const queued = await enqueue(message);
			if (!queued) {
				return toolResult(id, "The user's Mac is offline, and Porchlight couldn't save this request for later. Try again when the Mac is back.", true);
			}
			return toolResult(
				id,
				"The user's Mac is offline, so Porchlight saved this request. It will run when the Mac is back, "
					+ `and Porchlight may ask the user to approve it first. (Queued as ${queued.slice(0, 8)}.)`,
				false,
			);
		}
		default:
			return rpcError(id, -32001, "Porchlight host is offline");
	}
}

function result(id: unknown, value: unknown): Message {
	return { jsonrpc: "2.0", id, result: value };
}

function toolResult(id: unknown, text: string, isError: boolean): Message {
	return result(id, { content: [{ type: "text", text }], isError });
}

function rpcError(id: unknown, code: number, message: string): Message {
	return { jsonrpc: "2.0", id, error: { code, message } };
}
