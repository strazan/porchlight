import { fromBase64, toBase64 } from "./bytes";
import type { Catalog, QueuedFrame } from "./protocol";
import { seal } from "./seal";

// Requests saved while the host is offline: how long they keep, how many, how big.
export const QUEUE_TTL_MS = 7 * 24 * 3600_000;
export const MAX_QUEUED = 100;
const MAX_QUEUED_BODY = 256 * 1024;

const KEY = "queuekey";
const CATALOG = "catalog:";
// `queue:<13-digit ms>-<id>`, so listing returns items oldest first; `queueid:<id>` → that key.
const ITEM = "queue:";
const INDEX = "queueid:";

interface QueuedItem {
	frame: QueuedFrame;
	/** So revoking the app drops what it queued. */
	grantId: string;
}

/** Who saved a request, as the relay's OAuth established it. */
export interface Sender {
	grantId: string;
	clientId: string;
	clientName: string;
}

/**
 * What lets an app keep working while the host is offline: the catalog the host sent for it,
 * and its saved requests, sealed to the host's key. See "Offline queue" in PROTOCOL.md.
 */
export class OfflineQueue {
	constructor(private readonly storage: DurableObjectStorage) {}

	/** The host's public key (base64, uncompressed P-256 point). Hosts without one get no queue. */
	async setKey(key: string): Promise<void> {
		if (decodesTo(key, 65)) await this.storage.put(KEY, key);
	}

	async catalog(clientId: string): Promise<Catalog | undefined> {
		return clientId ? this.storage.get<Catalog>(CATALOG + clientId) : undefined;
	}

	async setCatalog(clientId: string, catalog: Catalog | null): Promise<void> {
		if (catalog) await this.storage.put(CATALOG + clientId, catalog);
		else await this.storage.delete(CATALOG + clientId);
	}

	/** Seals and saves one JSON-RPC message; null if it can't be saved (no key, too big, full). */
	async add(message: unknown, path: string, sender: Sender): Promise<QueuedFrame | null> {
		const key = await this.storage.get<string>(KEY);
		if (!key) return null;
		const plaintext = new TextEncoder().encode(JSON.stringify(message));
		if (plaintext.length > MAX_QUEUED_BODY) return null;
		if ((await this.storage.list({ prefix: INDEX, limit: MAX_QUEUED })).size >= MAX_QUEUED) return null;

		const id = crypto.randomUUID();
		const now = Date.now();
		const frame: QueuedFrame = {
			id,
			client_id: sender.clientId,
			client_name: sender.clientName,
			path,
			queued_at: now,
			sealed: toBase64(await seal(fromBase64(key), plaintext, id)),
		};
		const itemKey = `${ITEM}${String(now).padStart(13, "0")}-${id}`;
		await this.storage.put({ [itemKey]: { frame, grantId: sender.grantId } satisfies QueuedItem, [INDEX + id]: itemKey });
		return frame;
	}

	/** Saved requests that haven't expired, oldest first. */
	async waiting(): Promise<QueuedFrame[]> {
		const now = Date.now();
		return [...(await this.storage.list<QueuedItem>({ prefix: ITEM })).values()]
			.filter((item) => item.frame.queued_at + QUEUE_TTL_MS > now)
			.map((item) => item.frame);
	}

	/** The host ran (or gave up on) a request. Repeats are harmless. */
	async done(id: string): Promise<void> {
		const itemKey = await this.storage.get<string>(INDEX + id);
		if (itemKey) await this.storage.delete([itemKey, INDEX + id]);
	}

	async dropGrant(grantId: string): Promise<void> {
		for (const [key, item] of await this.storage.list<QueuedItem>({ prefix: ITEM })) {
			if (item.grantId === grantId) await this.storage.delete([key, INDEX + item.frame.id]);
		}
	}

	/** Deletes expired requests; returns when the next one expires, if any are left. */
	async expire(now: number): Promise<number | undefined> {
		let next: number | undefined;
		for (const [key, item] of await this.storage.list<QueuedItem>({ prefix: ITEM })) {
			const expires = item.frame.queued_at + QUEUE_TTL_MS;
			if (expires <= now) await this.storage.delete([key, INDEX + item.frame.id]);
			else next = Math.min(next ?? expires, expires);
		}
		return next;
	}
}

function decodesTo(b64: string, length: number): boolean {
	try {
		return fromBase64(b64).length === length;
	} catch {
		return false;
	}
}
