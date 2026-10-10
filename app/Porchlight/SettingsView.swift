import PorchlightCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ServersTab().tabItem { Label("Servers", systemImage: "server.rack") }
            ClientsTab().tabItem { Label("Apps", systemImage: "app.connected.to.app.below.fill") }
            RelayTab().tabItem { Label("Relay", systemImage: "network") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 600, height: 460)
    }
}

// MARK: - Servers

private struct ServersTab: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<ServerConfig.ID> = []
    @State private var editing: ServerConfig?
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            if model.servers.isEmpty {
                ContentUnavailableView {
                    Label("No Servers", systemImage: "server.rack")
                } description: {
                    Text("Add a local MCP server, or import the ones you already use in Claude Desktop, Claude Code or Cursor.")
                } actions: {
                    Button("Import…") { importing = true }
                    Button("Add Server…") { editing = newServer() }
                }
            } else {
                List(selection: $selection) {
                    ForEach(model.servers) { server in
                        ServerRow(server: server).tag(server.id)
                    }
                }
                .contextMenu(forSelectionType: ServerConfig.ID.self) { ids in
                    if ids.count == 1, let server = server(ids.first) {
                        Button("Edit…") { editing = server }
                    }
                    Button("Delete", role: .destructive) { model.remove(ids) }
                } primaryAction: { ids in
                    if let server = server(ids.first) { editing = server }
                }
                .onDeleteCommand { model.remove(selection) }
            }

            Divider()
            HStack(spacing: 4) {
                Button { editing = newServer() } label: { Image(systemName: "plus") }
                    .help("Add a server")
                Button { model.remove(selection) } label: { Image(systemName: "minus") }
                    .help("Remove the selected servers")
                    .disabled(selection.isEmpty)
                Button("Edit…") { editing = server(selection.first) }
                    .disabled(selection.count != 1)
                Spacer()
                Button("Import…") { importing = true }
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .sheet(item: $editing) { server in
            ServerEditor(server: server, isNew: !model.servers.contains { $0.id == server.id })
        }
        .sheet(isPresented: $importing) { ImportView() }
    }

    private func server(_ id: ServerConfig.ID?) -> ServerConfig? {
        model.servers.first { $0.id == id }
    }

    private func newServer() -> ServerConfig {
        ServerConfig(name: "", command: "")
    }
}

private struct ServerRow: View {
    @Environment(AppModel.self) private var model
    let server: ServerConfig

    var body: some View {
        let status = model.status(of: server)
        HStack(spacing: 10) {
            StatusDot(status: server.enabled ? status : .idle)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.body.weight(.medium))
                Text(server.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if server.enabled, case .failed(let reason) = status {
                    Text(reason).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { server.enabled }, set: { model.setEnabled($0, for: server) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Apps

private struct ClientsTab: View {
    @Environment(AppModel.self) private var model
    @State private var revoking: PairedClient?
    @State private var editingAccess: PairedClient?

    private func accessSummary(_ client: PairedClient) -> String {
        guard let servers = model.access(for: client.clientID) else { return "Access: all servers" }
        return servers.isEmpty ? "Access: no servers" : "Access: \(servers.sorted().joined(separator: ", "))"
    }

    var body: some View {
        Group {
            if !model.isConnected {
                ContentUnavailableView(
                    "Not Connected",
                    systemImage: "network.slash",
                    description: Text("Connect to your relay to see which apps have access.")
                )
            } else if model.clients.isEmpty {
                ContentUnavailableView {
                    Label("No Connected Apps", systemImage: "app.connected.to.app.below.fill")
                } description: {
                    Text("Add \(model.endpoint) as a custom connector in Claude, ChatGPT or another MCP client. You'll approve it here.")
                } actions: {
                    CopyButton(text: model.endpoint, help: "Copy the URL")
                }
            } else {
                List(model.clients) { client in
                    HStack(spacing: 10) {
                        Image(systemName: "app.connected.to.app.below.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(client.clientName).font(.body.weight(.medium))
                            Text(client.clientDomain ?? client.clientID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("Connected \(client.createdAt, format: .relative(presentation: .named))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(accessSummary(client))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Button("Access…") { editingAccess = client }
                            Button("Revoke…") { revoking = client }
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .sheet(item: $editingAccess) { client in AccessEditor(client: client) }
        .safeAreaInset(edge: .bottom) {
            if model.isConnected {
                HStack {
                    Spacer()
                    Button("Refresh") { model.refreshClients() }
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        }
        .onAppear { model.refreshClients() }
        .confirmationDialog(
            "Revoke access for \(revoking?.clientName ?? "this app")?",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            presenting: revoking
        ) { client in
            Button("Revoke", role: .destructive) { model.revoke(client) }
        } message: { _ in
            Text("It stops working right away. To use it again, connect it again and approve it here.")
        }
    }
}

private struct AccessEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let client: PairedClient
    @State private var access: Set<String>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What can \(client.clientName) use?").font(.title3.weight(.semibold))
            ServerAccessPicker(servers: model.servers.map(\.name), selection: $access)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setAccess(clientID: client.clientID, servers: access)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380, height: 360)
        .onAppear { access = model.access(for: client.clientID) }
    }
}

// MARK: - Relay

private struct RelayTab: View {
    @Environment(AppModel.self) private var model
    @State private var relayURL = ""
    @State private var secret = ""
    @State private var deploying = false
    @State private var updateStep: RelayDeployer.Step?
    @State private var updateError: String?

    var body: some View {
        Form {
            Section {
                if let deployment = model.deployment {
                    LabeledContent("Deployed to", value: deployment.accountName)
                    if model.relayUpdateAvailable {
                        HStack {
                            Text(updateStep?.title ?? "A newer relay comes with this version of Porchlight.")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Update Relay") { update() }
                                .disabled(updateStep != nil)
                        }
                    } else {
                        Text("The relay is up to date.").foregroundStyle(.secondary)
                    }
                    if let updateError {
                        Text(updateError).foregroundStyle(.red).font(.callout)
                    }
                    Button("Deploy Again…") { deploying = true }
                } else {
                    HStack {
                        Text("Run your relay in your own Cloudflare account. It takes about a minute and fits in the free plan.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Deploy to Cloudflare…") { deploying = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } header: {
                Text("Cloudflare")
            }

            Section {
                TextField("URL", text: $relayURL, prompt: Text("https://porchlight-relay.you.workers.dev"))
                SecureField("Secret", text: $secret, prompt: Text("AGENT_SECRET"))
                HStack {
                    Spacer()
                    Button("Save & Reconnect") { save() }
                        .disabled(relayURL.isEmpty || secret.isEmpty || !changed)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Filled in for you when Porchlight deploys the relay. For a relay you deployed yourself, enter its URL and AGENT_SECRET.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
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

// MARK: - General

private struct GeneralTab: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Open Porchlight at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LoginItem.set(enabled)
                            loginItemError = nil
                        } catch {
                            loginItemError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if LoginItem.needsApproval {
                    Text("Allow Porchlight in System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                Toggle("Keep this Mac awake while Porchlight is on", isOn: $model.keepAwake)
            } footer: {
                Text("Cloud apps can only reach your servers while your Mac is awake. Closing the lid still puts it to sleep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
