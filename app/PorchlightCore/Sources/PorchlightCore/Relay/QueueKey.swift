import CryptoKit
import Foundation

/// The key requests saved by the relay while the Mac was offline are sealed to. The relay
/// gets the public half in `hello`; only this Mac can open what it sealed. The scheme
/// matches relay/src/seal.ts: ECDH (P-256) with an ephemeral key, HKDF-SHA256, AES-256-GCM
/// with the item's id as associated data.
public struct QueueKey: Sendable {
    private let privateKey: P256.KeyAgreement.PrivateKey
    private static let info = Data("porchlight-queue-v1".utf8)

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
        guard bytes.count >= 65 + 12 + 16 else { throw OpenError.malformed }
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: bytes[0..<65])
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Self.info, outputByteCount: 32)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: bytes[65..<77]),
            ciphertext: bytes[77..<(bytes.count - 16)],
            tag: bytes[(bytes.count - 16)...]
        )
        return try AES.GCM.open(box, using: key, authenticating: Data(associated.utf8))
    }
}

/// The queued requests this Mac has finished, so one delivered again (the relay resends
/// until it hears back) never runs twice. Keeps the most recent ones, in a file if given.
public final class QueueLedger: Sendable {
    private let file: URL?
    private let finished: Locked<[String]>
    static let limit = 500

    public init(file: URL? = nil) {
        self.file = file
        let saved = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        finished = Locked(saved ?? [])
    }

    public func contains(_ id: String) -> Bool {
        finished.withLock { $0.contains(id) }
    }

    public func add(_ id: String) {
        let snapshot = finished.withLock { ids -> [String] in
            guard !ids.contains(id) else { return ids }
            ids.append(id)
            if ids.count > Self.limit { ids.removeFirst(ids.count - Self.limit) }
            return ids
        }
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
    }
}
