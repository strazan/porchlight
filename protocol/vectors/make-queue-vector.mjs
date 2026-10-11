// Writes queue.json: a request sealed the way the relay seals queued requests
// (relay/src/seal.ts), with the recipient's private key, so the relay's and the Mac's
// tests can both check they agree on the format. Run: node make-queue-vector.mjs
import { writeFileSync } from "node:fs";

const curve = { name: "ECDH", namedCurve: "P-256" };
const recipient = await crypto.subtle.generateKey(curve, true, ["deriveBits"]);
const ephemeral = await crypto.subtle.generateKey(curve, true, ["deriveBits"]);
const id = "3f1c9a52-0d7e-4b8a-9a61-6c2f8f3e7b10";
const plaintext = JSON.stringify({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "reminders__create_reminder", arguments: { title: "Oat milk" } } });

const shared = await crypto.subtle.deriveBits({ name: "ECDH", public: recipient.publicKey }, ephemeral.privateKey, 256);
const hkdf = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
const key = await crypto.subtle.deriveKey(
	{ name: "HKDF", hash: "SHA-256", salt: new Uint8Array(), info: new TextEncoder().encode("porchlight-queue-v1") },
	hkdf, { name: "AES-GCM", length: 256 }, false, ["encrypt"],
);
const nonce = crypto.getRandomValues(new Uint8Array(12));
const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: new TextEncoder().encode(id) }, key, new TextEncoder().encode(plaintext)));
const ephemeralRaw = new Uint8Array(await crypto.subtle.exportKey("raw", ephemeral.publicKey));
const sealed = Buffer.concat([ephemeralRaw, nonce, ciphertext]).toString("base64");
const jwk = await crypto.subtle.exportKey("jwk", recipient.privateKey);

writeFileSync(new URL("queue.json", import.meta.url), JSON.stringify({
	about: "A queued request sealed to `private_key` (P-256, d as base64url, as in a JWK). See make-queue-vector.mjs.",
	private_key: { d: jwk.d, x: jwk.x, y: jwk.y },
	id,
	sealed,
	plaintext,
}, null, "\t") + "\n");
