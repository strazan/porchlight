import PorchlightCore
import SwiftUI

struct SettingsView: View {
    enum Tab: Hashable, CaseIterable {
        case servers, apps, relay, general
    }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab

    init(tab: Tab = .servers) {
        _tab = State(initialValue: tab)
    }

    var body: some View {
        TabView(selection: $tab) {
            ServersTab().tabItem { Label("Servers", systemImage: "server.rack") }.tag(Tab.servers)
            ClientsTab().tabItem { Label("Apps", systemImage: "person.2") }.tag(Tab.apps)
            RelayTab().tabItem { Label("Relay", systemImage: "network") }.tag(Tab.relay)
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
        }
        .frame(width: 620, height: 480)
        .onAppear(perform: openRequestedTab)
        .onChange(of: model.requestedSettingsTab) { openRequestedTab() }
    }

    private func openRequestedTab() {
        if let requested = model.requestedSettingsTab {
            tab = requested
            model.requestedSettingsTab = nil
        }
    }
}

/// A list in a bordered box with a bar attached underneath, as in System Settings.
private struct ListBox<Content: View, Bar: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var bar: Bar

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            bar
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

private struct Footnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Servers

private struct ServersTab: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<ServerConfig.ID> = []
    @State private var editing: ServerConfig?
    @State private var changingIcon: ServerConfig?
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ListBox {
                if model.servers.isEmpty {
                    ContentUnavailableView {
                        Label("No Servers Yet", systemImage: "server.rack")
                    } description: {
                        Text("Add an MCP server that runs on this Mac, or import the ones you use in Claude Desktop, Claude Code or Cursor.")
                    } actions: {
                        Button("Import…") { importing = true }
                        Button("Add Server…") { editing = newServer() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List(selection: $selection) {
                        ForEach(model.servers) { server in
                            ServerRow(server: server) { editing = server }
                                .tag(server.id)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .contextMenu(forSelectionType: ServerConfig.ID.self) { ids in
                        if ids.count == 1, let server = server(ids.first) {
                            Button("Edit…") { editing = server }
                            Button("Change Icon…") { changingIcon = server }
                            Divider()
                        }
                        Button("Remove", role: .destructive) { model.remove(ids) }
                    } primaryAction: { ids in
                        if let server = server(ids.first) { editing = server }
                    }
                    .onDeleteCommand { model.remove(selection) }
                }
            } bar: {
                ListBar(add: { editing = newServer() }, remove: { model.remove(selection) }, canRemove: !selection.isEmpty) {
                    if !model.servers.isEmpty {
                        Button("Import…") { importing = true }
                            .padding(.trailing, 6)
                    }
                }
            }
            if !model.servers.isEmpty {
                Footnote("Cloud agents see each server's tools as server__tool. Double-click a server to edit it.")
            }
        }
        .padding(20)
        .sheet(item: $editing) { server in
            ServerEditor(server: server, isNew: !model.servers.contains { $0.id == server.id })
        }
        .sheet(isPresented: $importing) { ImportView() }
        .sheet(item: $changingIcon) { server in ServerIconPicker(server: server) }
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
    let edit: () -> Void

    var body: some View {
        let status = server.enabled ? model.status(of: server) : .idle
        HStack(spacing: 12) {
            ServerIcon(server: server, size: 30, status: status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name).font(.body.weight(.medium))
                    if server.transport == .http { Badge(text: "URL", color: .secondary) }
                }
                Text(server.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let problem = status.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button(action: edit) { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Edit \(server.name)")
            Toggle("Enabled", isOn: Binding(get: { server.enabled }, set: { model.setEnabled($0, for: server) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Apps

private struct ClientsTab: View {
    @Environment(AppModel.self) private var model
    @State private var revoking: AppModel.ConnectedApp?
    @State private var editingAccess: PairedClient?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ListBox {
                Group {
                    if !model.isConnected {
                        ContentUnavailableView(
                            "Not Connected",
                            systemImage: "network.slash",
                            description: Text("Turn Porchlight on to see which apps have access.")
                        )
                    } else if model.apps.isEmpty {
                        ContentUnavailableView {
                            Label("No Apps Yet", systemImage: "person.2")
                        } description: {
                            Text("Add the connector URL as a custom connector in Claude, ChatGPT or another MCP client. You'll approve it on this Mac.")
                        } actions: {
                            CopyButton(text: model.endpoint, label: "Copy Connector URL")
                        }
                    } else {
                        List(model.apps) { app in
                            ClientRow(app: app, access: model.access(for: app.id)) {
                                editingAccess = app.latest
                            } revoke: {
                                revoking = app
                            }
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                    }
                }
                .frame(maxHeight: .infinity)
            } bar: {
                HStack {
                    Text(model.apps.count == 1 ? "1 app" : "\(model.apps.count) apps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                    Spacer()
                    Button { model.refreshClients() } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 20) }
                        .buttonStyle(.borderless)
                        .help("Refresh")
                        .disabled(!model.isConnected)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            Footnote("Apps reach your servers through the relay after you approve them. Revoking an app stops it right away.")
        }
        .padding(20)
        .onAppear { model.refreshClients() }
        .sheet(item: $editingAccess) { client in AccessEditor(client: client) }
        .confirmationDialog(
            "Revoke access for \(revoking?.latest.clientName ?? "this app")?",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            presenting: revoking
        ) { app in
            Button("Revoke", role: .destructive) { model.revoke(app) }
        } message: { app in
            Text(app.connections.count > 1
                ? "All \(app.connections.count) of its connections stop working right away. To use it again, connect it again and approve it here."
                : "It stops working right away. To use it again, connect it again and approve it here.")
        }
    }
}

private struct ClientRow: View {
    let app: AppModel.ConnectedApp
    let access: Set<String>?
    let changeAccess: () -> Void
    let revoke: () -> Void
    @State private var changingIcon = false
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(clientID: client.clientID, name: client.clientName, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(client.clientName).font(.body.weight(.medium))
                    if client.clientDomain != nil {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .help("Its name is verified")
                    }
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(accessSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Button("Change Access…", action: changeAccess)
                Button("Change Icon…") { changingIcon = true }
                Divider()
                Button("Revoke…", role: .destructive, action: revoke)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Access and revoke")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Change Access…", action: changeAccess)
            Button("Change Icon…") { changingIcon = true }
            Button("Revoke…", role: .destructive, action: revoke)
        }
        .sheet(isPresented: $changingIcon) {
            IconPicker(
                key: IconStore.key(app: app.id),
                title: "Icon for \(client.clientName)",
                defaultWebsite: model.defaultIconWebsite(forApp: app.id),
                plainLabel: "Initial"
            ) {
                AppIcon(clientID: app.id, name: client.clientName, size: 48)
            }
        }
    }

    private var client: PairedClient { app.latest }

    private var details: String {
        let origin = client.clientDomain ?? "Unverified name"
        let connections = app.connections.count > 1 ? " · \(app.connections.count) connections" : ""
        return "\(origin) · connected \(client.createdAt.formatted(.relative(presentation: .named)))\(connections)"
    }

    private var accessSummary: String {
        guard let access else { return "Can use all servers" }
        if access.isEmpty { return "Can't use any server" }
        return "Can use " + access.sorted().joined(separator: ", ")
    }
}

struct AccessEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let client: PairedClient
    @State private var access: Set<String>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AppIcon(clientID: client.clientID, name: client.clientName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What can \(client.clientName) use?").font(.title3.weight(.semibold))
                    Text("It won't see servers you leave out.").font(.callout).foregroundStyle(.secondary)
                }
            }
            ServerAccessPicker(servers: model.servers.map(\.name), selection: $access)
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
        .frame(width: 380)
        .onAppear { access = model.access(for: client.clientID) }
    }
}

// MARK: - Relay

private struct RelayTab: View {
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
                        StatusDot(statusColor)
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
                    Footnote("Add the connector URL as a custom connector in Claude, ChatGPT or any MCP client.")
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
                    SecureField("Secret", text: $secret, prompt: Text("AGENT_SECRET"))
                    HStack {
                        Spacer()
                        Button("Save & Reconnect") { save() }
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

    private var statusColor: Color {
        switch model.state {
        case .off: .secondary.opacity(0.5)
        case .starting, .relay(.connecting): .yellow
        case .relay(.connected): .green
        case .relay(.disconnected): .red
        }
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
                Toggle("Open at login", isOn: $launchAtLogin)
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
                    Label("Allow Porchlight in System Settings → General → Login Items.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let loginItemError {
                    Text(loginItemError).font(.callout).foregroundStyle(.red)
                }
                Toggle(isOn: $model.keepAwake) {
                    Text("Keep this Mac awake while Porchlight is on")
                    Text("Cloud agents can only reach your servers while your Mac is awake. Closing the lid still puts it to sleep.")
                }
                Toggle(isOn: Binding(get: { model.icons.fetchFromWebsites }, set: { model.icons.fetchFromWebsites = $0 })) {
                    Text("Show icons from websites")
                    Text("Downloads icons for apps and servers from their websites, like claude.ai or obsidian.md.")
                }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                LabeledContent("Source code") {
                    Link("github.com/strazan/porchlight", destination: URL(string: "https://github.com/strazan/porchlight")!)
                }
                LabeledContent("License", value: "MIT")
            }
        }
        .formStyle(.grouped)
    }
}
