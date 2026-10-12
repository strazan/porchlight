import type { PairingInfo, RelayToHost } from "./protocol";

// As long as the consent page's handle stays valid.
const PAIRING_TTL_MS = 10 * 60_000;
// Anyone can open the consent page, so cap how many prompts can wait on the Mac.
export const MAX_PAIRINGS = 5;
const PREFIX = "pair:";

interface PairingRecord extends PairingInfo {
	code: string;
	/** SHA-256 of the consent page's handle: the approval only completes that page. */
	handleHash: string;
	state: "pending" | "approved" | "denied";
	expiresAt: number;
}

/** What the consent page shows: a code to compare with the Mac, or why there's none. */
export type Pairing = { id: string; code: string } | { offline: true } | { busy: true };

export type PairingState = PairingRecord["state"] | "expired" | "offline";

/** Apps waiting on the consent page for the owner's answer on their Mac. */
export class Pairings {
	constructor(private readonly storage: DurableObjectStorage) {}

	/** Null when too many are already waiting. */
	async start(info: PairingInfo, handleHash: string): Promise<{ frame: PairRequest; expiresAt: number } | null> {
		const now = Date.now();
		const waiting = [...(await this.storage.list<PairingRecord>({ prefix: PREFIX })).values()];
		if (waiting.filter((record) => record.expiresAt > now).length >= MAX_PAIRINGS) return null;
		const id = crypto.randomUUID();
		const code = String(crypto.getRandomValues(new Uint32Array(1))[0]! % 1_000_000).padStart(6, "0");
		const record: PairingRecord = { ...info, code, handleHash, state: "pending", expiresAt: now + PAIRING_TTL_MS };
		await this.storage.put(PREFIX + id, record);
		return { frame: pairRequest(id, record), expiresAt: record.expiresAt };
	}

	/** The `pair_request` frames for pairings still waiting, to send to a host that just connected. */
	async pending(): Promise<PairRequest[]> {
		const frames: PairRequest[] = [];
		for (const [key, record] of await this.storage.list<PairingRecord>({ prefix: PREFIX })) {
			if (record.state === "pending" && record.expiresAt > Date.now()) frames.push(pairRequest(key.slice(PREFIX.length), record));
		}
		return frames;
	}

	async state(id: string): Promise<PairingRecord["state"] | "expired"> {
		const record = await this.storage.get<PairingRecord>(PREFIX + id);
		return !record || record.expiresAt <= Date.now() ? "expired" : record.state;
	}

	async decide(id: string, allow: boolean): Promise<void> {
		const record = await this.storage.get<PairingRecord>(PREFIX + id);
		if (!record || record.state !== "pending") return;
		await this.storage.put(PREFIX + id, { ...record, state: allow ? "approved" : "denied" });
	}

	/** Completes an approved pairing, once, for the consent page it was started from. */
	async consume(id: string, handleHash: string): Promise<PairingInfo | null> {
		const record = await this.storage.get<PairingRecord>(PREFIX + id);
		if (!record || record.state !== "approved" || record.handleHash !== handleHash || record.expiresAt <= Date.now()) {
			return null;
		}
		await this.storage.delete(PREFIX + id);
		const { client_id, client_name, client_domain, redirect_host, loopback } = record;
		return { client_id, client_name, client_domain, redirect_host, loopback };
	}

	/** Deletes expired pairings; returns when the next one expires, if any are left. */
	async expire(now: number): Promise<number | undefined> {
		let next: number | undefined;
		for (const [key, record] of await this.storage.list<PairingRecord>({ prefix: PREFIX })) {
			if (record.expiresAt <= now) await this.storage.delete(key);
			else next = Math.min(next ?? record.expiresAt, record.expiresAt);
		}
		return next;
	}
}

type PairRequest = Extract<RelayToHost, { type: "pair_request" }>;

function pairRequest(id: string, record: PairingRecord): PairRequest {
	const { code, client_id, client_name, client_domain, redirect_host, loopback } = record;
	return { type: "pair_request", id, code, client_id, client_name, client_domain, redirect_host, loopback };
}
