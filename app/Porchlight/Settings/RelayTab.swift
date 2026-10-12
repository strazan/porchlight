import PorchlightCore
import SwiftUI

/// Where the relay runs, and how this Mac connects to it.
struct RelayTab: View {
    @Environment(AppModel.self) private var model
    @State private var relayURL = ""
    @State private var secret = ""
    @State private var deploying = false
    @State private var showAdvanced = false
    @State private var updateStep: RelayDeployer.Step?
    @State private var updateError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        StatusDot(model.state.color)
                        Text(model.statusText)
                    }
                }
                if model.isConfigured {
                    LabeledContent("Connector URL") {
                        HStack(spacing: 6) {
                            Text(model.endpoint)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            CopyButton(text: model.endpoint)
                                .buttonStyle(.borderless)
                        }
                    }
                }
            } footer: {
                if model.isConfigured {
                    Footnote("Add the connector URL as a custom connector in Claude, ChatGPT or another MCP client.")
                }
            }

            Section("Cloudflare") {
                if let deployment = model.deployment {
                    LabeledContent("Account", value: deployment.accountName)
                    LabeledContent("Relay") {
                        if let updateStep {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(updateStep.title).foregroundStyle(.secondary)
                            }
                        } else if model.relayUpdateAvailable {
                            HStack(spacing: 8) {
                                Text("Update available").foregroundStyle(.secondary)
                                Button("Update") { update() }
                            }
                        } else {
                            Text("Up to date").foregroundStyle(.secondary)
                        }
                    }
                    if let updateError {
                        Label(updateError, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    HStack {
                        Spacer()
                        Button("Redeploy…") { deploying = true }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Porchlight needs a relay on the internet that cloud agents can reach. Deploy one to your own Cloudflare account: it takes about a minute and fits in the free plan.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Deploy to Cloudflare…") { deploying = true }
                            .buttonStyle(.borderedProminent)
                            .tint(.porchlight)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                DisclosureGroup("Use a relay you deployed yourself", isExpanded: $showAdvanced) {
                    TextField("URL", text: $relayURL, prompt: Text("https://porchlight-relay.you.workers.dev"))
                    SecureField("Secret", text: $secret, prompt: Text("HOST_SECRET"))
                    HStack {
                        Spacer()
                        Button("Save and Reconnect") { save() }
                            .disabled(relayURL.isEmpty || secret.isEmpty || !changed)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            load()
            showAdvanced = model.deployment == nil && model.isConfigured
        }
        .onChange(of: model.relayURL) { load() }
        .sheet(isPresented: $deploying) { DeployView() }
    }

    private var changed: Bool { relayURL != model.relayURL || secret != model.secret || !model.isOn }

    private func load() {
        relayURL = model.relayURL
        secret = model.secret
    }

    private func save() {
        model.relayURL = relayURL
        if secret != model.secret { model.secret = secret }
        model.restart()
    }

    private func update() {
        updateError = nil
        updateStep = .subdomain
        Task {
            do {
                try await model.updateRelay { step in
                    Task { @MainActor in updateStep = step }
                }
            } catch {
                updateError = error.localizedDescription
            }
            updateStep = nil
        }
    }
}
