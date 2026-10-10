// Wire protocol between the relay and the Porchlight host. See protocol/PROTOCOL.md.

export const PROTOCOL_VERSION = 1;

// Exact strings so the Durable Object can answer keepalives without waking up.
export const PING = '{"type":"ping"}';
export const PONG = '{"type":"pong"}';

export type HeaderList = [name: string, value: string][];

export type RelayToHost =
	| { type: "req"; id: string; method: string; path: string; headers: HeaderList; body_b64: string }
	| { type: "cancel"; id: string };

export type HostToRelay =
	| { type: "hello"; proto: number; app_version: string }
	| { type: "res_start"; id: string; status: number; headers: HeaderList }
	| { type: "res_chunk"; id: string; data_b64: string }
	| { type: "res_end"; id: string };

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
