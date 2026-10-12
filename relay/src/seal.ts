// Encrypts queued requests to the host's public key (ECIES): an ephemeral P-256 key, ECDH
// with the host's key, HKDF-SHA256, then AES-256-GCM with the queue item's id as associated
// data. Once sealed, the relay itself can't read them back. The host opens them with
// CryptoKit (QueueKey.swift); protocol/vectors/queue.json checks the two agree.

import { concat } from "./bytes";

const INFO = new TextEncoder().encode("porchlight-queue-v1");
const CURVE = { name: "ECDH", namedCurve: "P-256" } as const;

/** `recipient` is the host's public key as an uncompressed point (65 bytes). */
export async function seal(recipient: Uint8Array, plaintext: Uint8Array, associated: string): Promise<Uint8Array> {
	const theirs = await crypto.subtle.importKey("raw", recipient, CURVE, false, []);
	const ours = (await crypto.subtle.generateKey(CURVE, true, ["deriveBits"])) as CryptoKeyPair;
	const key = await aesKey(ours.privateKey, theirs, ["encrypt"]);
	const nonce = crypto.getRandomValues(new Uint8Array(12));
	const ciphertext = await crypto.subtle.encrypt(
		{ name: "AES-GCM", iv: nonce, additionalData: new TextEncoder().encode(associated) },
		key,
		plaintext,
	);
	const ephemeral = new Uint8Array((await crypto.subtle.exportKey("raw", ours.publicKey)) as ArrayBuffer);
	return concat(ephemeral, nonce, new Uint8Array(ciphertext));
}

/** The reverse of `seal`, for tests (the relay never opens what it sealed). */
export async function open(privateKey: CryptoKey, sealed: Uint8Array, associated: string): Promise<Uint8Array> {
	const theirs = await crypto.subtle.importKey("raw", sealed.slice(0, 65), CURVE, false, []);
	const key = await aesKey(privateKey, theirs, ["decrypt"]);
	const plaintext = await crypto.subtle.decrypt(
		{ name: "AES-GCM", iv: sealed.slice(65, 77), additionalData: new TextEncoder().encode(associated) },
		key,
		sealed.slice(77),
	);
	return new Uint8Array(plaintext);
}

async function aesKey(privateKey: CryptoKey, publicKey: CryptoKey, usages: string[]): Promise<CryptoKey> {
	// The runtime reads `public`; workerd's types spell it `$public`.
	const ecdh = { name: "ECDH", public: publicKey } as unknown as SubtleCryptoDeriveKeyAlgorithm;
	const shared = await crypto.subtle.deriveBits(ecdh, privateKey, 256);
	const hkdf = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
	return crypto.subtle.deriveKey(
		{ name: "HKDF", hash: "SHA-256", salt: new Uint8Array(), info: INFO },
		hkdf,
		{ name: "AES-GCM", length: 256 },
		false,
		usages,
	);
}
