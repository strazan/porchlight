// Wire protocol between the relay and the Porchlight host. See protocol/PROTOCOL.md.

export const PROTOCOL_VERSION = 1;

// Exact strings so the Durable Object can answer keepalives without waking up.
export const PING = '{"type":"ping"}';
export const PONG = '{"type":"pong"}';

export type HeaderList = [name: string, value: string][];

/** An app asking to connect, as shown on the consent page and on the host. */
export interface PairingInfo {
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

export type RelayToHost =
	| { type: "req"; id: string; method: string; path: string; headers: HeaderList; body_b64: string }
	| { type: "cancel"; id: string }
	| ({ type: "pair_request"; id: string; code: string } & PairingInfo)
	| { type: "clients"; items: ClientSummary[] };

export type HostToRelay =
	| { type: "hello"; proto: number; app_version: string }
	| { type: "res_start"; id: string; status: number; headers: HeaderList }
	| { type: "res_chunk"; id: string; data_b64: string }
	| { type: "res_end"; id: string }
	| { type: "pair_decision"; id: string; allow: boolean }
	| { type: "list_clients" }
	| { type: "revoke_client"; grant_id: string };

export function parseHostFrame(raw: string | ArrayBuffer): HostToRelay | null {
	if (typeof raw !== "string") return null;
	let msg: unknown;
	try {
		msg = JSON.parse(raw);
	} catch {
		return null;
	}
	if (typeof msg !== "object" || msg === null) return null;
	const m = msg as Record<string, unknown>;
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
		default:
			return null;
	}
}

export function toBase64(bytes: Uint8Array): string {
	let bin = "";
	for (let i = 0; i < bytes.length; i += 0x8000) {
		bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
	}
	return btoa(bin);
}

export function fromBase64(b64: string): Uint8Array {
	const bin = atob(b64);
	const out = new Uint8Array(bin.length);
	for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
	return out;
}
