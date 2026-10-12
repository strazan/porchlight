// Wire protocol between the relay and the Porchlight host. See protocol/PROTOCOL.md.

export const PROTOCOL_VERSION = 1;

// Exact strings so the Durable Object can answer keepalives without waking up.
export const PING = '{"type":"ping"}';
export const PONG = '{"type":"pong"}';

export type HeaderList = [name: string, value: string][];

/** An app asking to connect, as shown on the consent page and on the host. */
export interface PairingInfo {
	/** The OAuth client ID, so the host can remember per-app settings. */
	client_id: string;
	client_name: string;
	/** Verified domain, for clients identified by a Client ID Metadata Document. */
	client_domain?: string;
	/** Where the tokens will be sent. */
	redirect_host: string;
	/** The redirect goes to an app on the user's computer. */
	loopback: boolean;
}

/** A client that has been granted access. */
export interface ClientSummary {
	grant_id: string;
	client_id: string;
	client_name: string;
	client_domain?: string;
	/** Unix seconds. */
	created_at: number;
}

/**
 * What an app sees at one path (`/mcp` or `/mcp/<name>`) while the host is offline, as the
 * host last described it. See "Offline queue" in PROTOCOL.md.
 */
export interface CatalogPath {
	/** The `initialize` result to answer with. */
	initialize: Record<string, unknown>;
	/** The `tools/list` result's tools. */
	tools: unknown[];
	/** Tools whose calls may be saved for when the host is back. */
	queueable: string[];
}

export interface Catalog {
	/** Protocol versions the host speaks; a client asking for one of them gets it. */
	protocol_versions: string[];
	paths: Record<string, CatalogPath>;
}

/** A request saved while the host was offline. `sealed` can only be opened by the host. */
export interface QueuedFrame {
	id: string;
	client_id: string;
	client_name: string;
	path: string;
	/** Unix milliseconds. */
	queued_at: number;
	/** base64(ephemeral P-256 public key (65 bytes) ‖ nonce (12) ‖ AES-GCM ciphertext and tag). */
	sealed: string;
}

export type RelayToHost =
	| { type: "req"; id: string; method: string; path: string; headers: HeaderList; body_b64: string }
	| ({ type: "queued" } & QueuedFrame)
	| { type: "cancel"; id: string }
	| ({ type: "pair_request"; id: string; code: string } & PairingInfo)
	| { type: "clients"; items: ClientSummary[] };

export type HostToRelay =
	| { type: "hello"; proto: number; app_version: string; queue_key?: string }
	| { type: "res_start"; id: string; status: number; headers: HeaderList }
	| { type: "res_chunk"; id: string; data_b64: string }
	| { type: "res_end"; id: string }
	| { type: "pair_decision"; id: string; allow: boolean }
	| { type: "list_clients" }
	| { type: "revoke_client"; grant_id: string }
	| { type: "offline_catalog"; client_id: string; catalog: Catalog | null }
	| { type: "queued_done"; id: string };

export function parseHostFrame(raw: string | ArrayBuffer): HostToRelay | null {
	if (typeof raw !== "string") return null;
	let parsed: unknown;
	try {
		parsed = JSON.parse(raw);
	} catch {
		return null;
	}
	if (typeof parsed !== "object" || parsed === null) return null;
	const m = parsed as Record<string, unknown>;
	switch (m.type) {
		case "hello":
			return typeof m.proto === "number" ? (m as HostToRelay) : null;
		case "res_start":
			return typeof m.id === "string" && typeof m.status === "number" && Array.isArray(m.headers)
				? (m as HostToRelay)
				: null;
		case "res_chunk":
			return typeof m.id === "string" && typeof m.data_b64 === "string" ? (m as HostToRelay) : null;
		case "res_end":
			return typeof m.id === "string" ? (m as HostToRelay) : null;
		case "pair_decision":
			return typeof m.id === "string" && typeof m.allow === "boolean" ? (m as HostToRelay) : null;
		case "list_clients":
			return m as HostToRelay;
		case "revoke_client":
			return typeof m.grant_id === "string" ? (m as HostToRelay) : null;
		case "offline_catalog":
			return typeof m.client_id === "string" && (m.catalog === null || isCatalog(m.catalog)) ? (m as HostToRelay) : null;
		case "queued_done":
			return typeof m.id === "string" ? (m as HostToRelay) : null;
		default:
			return null;
	}
}

function isCatalog(value: unknown): value is Catalog {
	if (typeof value !== "object" || value === null) return false;
	const c = value as Record<string, unknown>;
	if (!Array.isArray(c.protocol_versions) || typeof c.paths !== "object" || c.paths === null) return false;
	return Object.values(c.paths as Record<string, unknown>).every((path) => {
		const p = path as Record<string, unknown> | null;
		return (
			typeof p === "object" && p !== null && typeof p.initialize === "object" && p.initialize !== null
			&& Array.isArray(p.tools) && Array.isArray(p.queueable)
		);
	});
}
