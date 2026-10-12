import CryptoKit
import Foundation

/// The key requests saved by the relay while the Mac was offline are sealed to. The relay
/// gets the public half in `hello`; only this Mac can open what it sealed. The scheme
/// matches relay/src/seal.ts: ECDH (P-256) with an ephemeral key, HKDF-SHA256, AES-256-GCM
/// with the item's id as associated data.
public struct QueueKey: Sendable {
    private let privateKey: P256.KeyAgreement.PrivateKey
    private static let info = Data("porchlight-queue-v1".utf8)
    // The sealed layout: ephemeral public key ‖ nonce ‖ ciphertext ‖ tag.
    private static let ephemeralKeyLength = 65
    private static let nonceLength = 12
    private static let tagLength = 16

    public init() {
        privateKey = P256.KeyAgreement.PrivateKey()
    }

    /// From `rawRepresentation`, e.g. as saved in the Keychain.
    public init(rawRepresentation: Data) throws {
        privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data { privateKey.rawRepresentation }

    /// The public key as the relay expects it: an uncompressed point, base64.
    public var publicKey: String { privateKey.publicKey.x963Representation.base64EncodedString() }

    public enum OpenError: Error {
        case malformed
    }

    /// `sealed` is ephemeral public key (65 bytes) ‖ nonce (12) ‖ ciphertext ‖ tag (16).
    public func open(_ sealed: Data, associated: String) throws -> Data {
        let bytes = [UInt8](sealed)
        let nonceStart = Self.ephemeralKeyLength
        let ciphertextStart = nonceStart + Self.nonceLength
        let tagStart = bytes.count - Self.tagLength
        guard tagStart >= ciphertextStart else { throw OpenError.malformed }
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: bytes[..<nonceStart])
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Self.info, outputByteCount: 32)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: bytes[nonceStart..<ciphertextStart]),
            ciphertext: bytes[ciphertextStart..<tagStart],
            tag: bytes[tagStart...]
        )
        return try AES.GCM.open(box, using: key, authenticating: Data(associated.utf8))
    }
}
