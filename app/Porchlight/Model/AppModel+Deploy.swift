import Foundation
import PorchlightCore
import Security

// Deploying the relay to the owner's Cloudflare account, and keeping it up to date.
extension AppModel {
    struct Deployment: Codable, Equatable {
        var accountID: String
        var accountName: String
        var scriptName: String
        /// The relay build that's deployed, from its bundle manifest.
        var relaySHA: String
    }

    enum UpdateError: LocalizedError {
        case notDeployedByApp

        var errorDescription: String? { "Deploy the relay from Porchlight first." }
    }

    var relayUpdateAvailable: Bool {
        guard let deployment, let bundledRelay else { return false }
        return deployment.relaySHA != bundledRelay.sha256
    }

    /// The Cloudflare token saved by an earlier deploy.
    var savedCloudflareToken: String {
        secrets.read(SecretAccount.cloudflareToken) ?? ""
    }

    /// Deploys the relay to a Cloudflare account and connects to it. A first deploy gets a
    /// fresh secret; redeploying to the same place keeps the current one.
    func deploy(
        token: String,
        account: CloudflareAPI.Account,
        progress: @escaping @Sendable (RelayDeployer.Step) -> Void
    ) async throws -> URL {
        guard let bundledRelay else { throw DeployError.bundleMissing }
        let sameTarget = deployment?.accountID == account.id
        let hostSecret = sameTarget && !secret.isEmpty ? secret : try Self.newSecret()
        let scriptName = deployment?.scriptName ?? RelayDeployer.defaultScriptName
        let deployer = RelayDeployer(api: CloudflareAPI(token: token), bundle: bundledRelay)
        log("Deploying the relay to \(account.name)…")
        let url = try await deployer.deploy(account: account.id, scriptName: scriptName, hostSecret: hostSecret, progress: progress)

        if !secrets.write(SecretAccount.cloudflareToken, token) {
            log("Couldn't save the Cloudflare token in the Keychain: updating the relay will ask for it again")
        }
        deployment = Deployment(accountID: account.id, accountName: account.name, scriptName: scriptName, relaySHA: bundledRelay.sha256)
        relayURL = url.absoluteString
        if hostSecret != secret { secret = hostSecret }
        log("Relay deployed at \(url.absoluteString)")
        restart()
        return url
    }

    /// Redeploys the relay that ships with this app, with the saved token.
    func updateRelay(progress: @escaping @Sendable (RelayDeployer.Step) -> Void) async throws {
        guard let deployment, !savedCloudflareToken.isEmpty else { throw UpdateError.notDeployedByApp }
        _ = try await deploy(token: savedCloudflareToken, account: .init(id: deployment.accountID, name: deployment.accountName), progress: progress)
    }

    /// 32 random bytes, hex: the secret the relay and this Mac share.
    static func newSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func loadDeployment() -> Deployment? {
        guard let data = defaults.data(forKey: "deployment") else { return nil }
        do {
            return try JSONDecoder().decode(Deployment.self, from: data)
        } catch {
            log("Couldn't read where the relay was deployed (\(error.localizedDescription)); deploy it again to update it")
            return nil
        }
    }

    func saveDeployment() {
        guard let deployment else { return defaults.removeObject(forKey: "deployment") }
        do {
            defaults.set(try JSONEncoder().encode(deployment), forKey: "deployment")
        } catch {
            log("Couldn't save where the relay was deployed: \(error.localizedDescription)")
        }
    }
}
