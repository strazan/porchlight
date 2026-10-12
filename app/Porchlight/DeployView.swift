import PorchlightCore
import SwiftUI

/// Deploys the relay to the user's Cloudflare account.
struct DeployView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    enum Stage: Equatable {
        case token
        case account
        case subdomain
        case deploying(RelayDeployer.Step)
        case done(URL)
    }

    init(stage: Stage = .token) {
        _stage = State(initialValue: stage)
    }

    @State private var stage: Stage
    @State private var token = ""
    @State private var accounts: [CloudflareAPI.Account] = []
    @State private var accountID = ""
    @State private var subdomain = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(
                title: "Deploy to Cloudflare",
                subtitle: "Your relay runs in your own Cloudflare account, within the free plan.",
                systemImage: "cloud.fill",
                tint: .orange
            )

            Group {
                switch stage {
                case .token: tokenStep
                case .account: accountStep
                case .subdomain: subdomainStep
                case .deploying(let step): progress(at: step)
                case .done(let url): doneStep(url)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                buttons
            }
        }
        .padding(24)
        .frame(width: 520, height: 420)
        .onAppear { if token.isEmpty { token = model.savedCloudflareToken } }
    }

    // MARK: Steps

    private var tokenStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Porchlight needs a Cloudflare API token that can edit Workers and Workers KV.")
            Button("Create a Token on Cloudflare…") { openURL(CloudflareAPI.createTokenURL) }
            Text("The permissions are filled in for you: choose **Continue to summary**, then **Create Token**, and paste it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("API token", text: $token)
                .textFieldStyle(.roundedBorder)
            Text("The token stays in your Keychain, so Porchlight can update the relay later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var accountStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which account should the relay run in?")
            Picker("Account", selection: $accountID) {
                ForEach(accounts) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
        }
    }

    private var subdomainStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This account doesn't have a workers.dev subdomain yet. Choose one; it's part of your relay's address and can't easily be changed.")
            HStack(spacing: 4) {
                Text("\(RelayDeployer.defaultScriptName).").foregroundStyle(.secondary)
                TextField("subdomain", text: $subdomain)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Text(".workers.dev").foregroundStyle(.secondary)
            }
            .font(.body.monospaced())
        }
    }

    private func progress(at current: RelayDeployer.Step) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(RelayDeployer.Step.allCases, id: \.self) { step in
                HStack(spacing: 8) {
                    Group {
                        if step < current {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if step == current, error == nil {
                            ProgressView().controlSize(.small)
                        } else if step == current {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 18)
                    Text(step.title).foregroundStyle(step > current ? .secondary : .primary)
                }
            }
        }
    }

    private func doneStep(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Your relay is live, and Porchlight is connecting to it.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text("Add this URL as a custom connector in Claude, ChatGPT or another MCP client:")
            HStack {
                Text(url.appending(path: "mcp").absoluteString)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                CopyButton(text: url.appending(path: "mcp").absoluteString, label: "Copy")
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Text("When it connects, you'll approve it here on your Mac.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch stage {
        case .token:
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Continue") { run(checkToken) }
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || busy)
        case .account:
            Button("Back") { stage = .token }
            Button("Continue") { run(checkSubdomain) }
                .keyboardShortcut(.defaultAction)
                .disabled(accountID.isEmpty || busy)
        case .subdomain:
            Button("Back") { stage = .account }
            Button("Claim and Deploy") { run(claimSubdomain) }
                .keyboardShortcut(.defaultAction)
                .disabled(subdomain.isEmpty || busy)
        case .deploying:
            if error != nil {
                Button("Close") { dismiss() }
                Button("Try Again") { run(deploy) }.keyboardShortcut(.defaultAction)
            }
        case .done:
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Actions

    private var api: CloudflareAPI { CloudflareAPI(token: token.trimmingCharacters(in: .whitespaces)) }

    private var account: CloudflareAPI.Account? { accounts.first { $0.id == accountID } }

    private func run(_ action: @escaping () async throws -> Void) {
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                try await action()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func checkToken() async throws {
        try await api.verifyToken()
        accounts = try await api.accounts()
        guard !accounts.isEmpty else {
            error = "This token can't see any accounts. Give it access to your account."
            return
        }
        accountID = model.deployment.flatMap { saved in accounts.first { $0.id == saved.accountID }?.id } ?? accounts[0].id
        if accounts.count == 1 {
            try await checkSubdomain()
        } else {
            stage = .account
        }
    }

    private func checkSubdomain() async throws {
        guard let account else { return }
        if try await api.workersSubdomain(account: account.id) == nil {
            subdomain = ServerConfig.slug(account.name.replacingOccurrences(of: "'s Account", with: ""))
            stage = .subdomain
        } else {
            try await deploy()
        }
    }

    private func claimSubdomain() async throws {
        guard let account else { return }
        _ = try await api.createWorkersSubdomain(account: account.id, name: subdomain)
        try await deploy()
    }

    private func deploy() async throws {
        guard let account else { return }
        stage = .deploying(.subdomain)
        let url = try await model.deploy(token: token.trimmingCharacters(in: .whitespaces), account: account) { step in
            Task { @MainActor in
                // A late update must not undo the final stage.
                if case .deploying = stage { stage = .deploying(step) }
            }
        }
        stage = .done(url)
    }
}
