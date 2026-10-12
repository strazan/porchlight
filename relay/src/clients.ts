import type { OAuthHelpers } from "@cloudflare/workers-oauth-provider";
import { OWNER } from "./oauth";
import type { ClientSummary } from "./protocol";

// KV listings can miss writes (new or revoked grants) for up to a minute; bridge longer.
const KV_LAG_MS = 5 * 60_000;
// Revoking deletes a grant's tokens by listing them, which can miss one issued in the
// last minute. Refuse revoked grants for longer than an access token lives (1 h).
const REVOKED_KEEP_MS = 2 * 3600_000;
const RECENT = "recent:";
const REVOKED = "revoked:";

/** The apps with access (OAuth grants), and revoking them. */
export class Clients {
	constructor(
		private readonly storage: DurableObjectStorage,
		/** Undefined until the relay knows its public origin (from the host's first connection). */
		private readonly oauth: () => Promise<OAuthHelpers | undefined>,
	) {}

	/** A grant just issued: KV lists can take a minute to include it, so it's remembered here until they do. */
	async remember(added: ClientSummary): Promise<void> {
		await this.storage.put(RECENT + (added.grant_id || added.client_id), { ...added, recorded: Date.now() });
	}

	async list(): Promise<ClientSummary[] | null> {
		const oauth = await this.oauth();
		if (!oauth) return null;
		const items: ClientSummary[] = [];
		const now = Date.now();
		const revoked = new Set<string>();
		for (const [key, at] of await this.storage.list<number>({ prefix: REVOKED })) {
			if (now - at < REVOKED_KEEP_MS) revoked.add(key.slice(REVOKED.length));
			else await this.storage.delete(key);
		}
		let cursor: string | undefined;
		do {
			const page = await oauth.listUserGrants(OWNER, { cursor });
			for (const grant of page.items) {
				if (revoked.has(grant.id)) continue; // revoked; KV hasn't caught up
				items.push({
					grant_id: grant.id,
					client_id: grant.clientId,
					client_name: grant.metadata?.client_name ?? grant.clientId,
					client_domain: grant.metadata?.client_domain,
					created_at: grant.createdAt,
				});
			}
			cursor = page.cursor;
		} while (cursor);
		// Grants issued moments ago, which KV may not list yet.
		for (const [key, recent] of await this.storage.list<ClientSummary & { recorded: number }>({ prefix: RECENT })) {
			const listed = items.some((item) =>
				recent.grant_id ? item.grant_id === recent.grant_id : item.client_id === recent.client_id,
			);
			if (listed || revoked.has(recent.grant_id) || now - recent.recorded >= KV_LAG_MS) {
				await this.storage.delete(key);
			} else {
				const { recorded: _, ...summary } = recent;
				items.push(summary);
			}
		}
		return items;
	}

	async revoke(grantId: string): Promise<void> {
		await this.storage.put(REVOKED + grantId, Date.now());
		await (await this.oauth())?.revokeGrant(grantId, OWNER);
	}

	async isRevoked(grantId: string): Promise<boolean> {
		return grantId !== "" && (await this.storage.get(REVOKED + grantId)) !== undefined;
	}
}
