import PorchlightCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ServersTab().tabItem { Label("Servers", systemImage: "server.rack") }
            RelayTab().tabItem { Label("Relay", systemImage: "network") }
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
                Text(server.commandLineString)
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

// MARK: - Relay

private struct RelayTab: View {
    @Environment(AppModel.self) private var model
    @State private var relayURL = ""
    @State private var secret = ""

    var body: some View {
        Form {
            Section {
                TextField("URL", text: $relayURL, prompt: Text("https://porchlight-relay.you.workers.dev"))
                SecureField("Secret", text: $secret, prompt: Text("AGENT_SECRET"))
            } footer: {
                Text("The relay you deployed to Cloudflare, and the AGENT_SECRET you gave it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Save & Reconnect") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(relayURL.isEmpty || secret.isEmpty || !changed)
            }
            .padding()
        }
        .onAppear {
            relayURL = model.relayURL
            secret = model.secret
        }
    }

    private var changed: Bool { relayURL != model.relayURL || secret != model.secret || !model.isOn }

    private func save() {
        model.relayURL = relayURL
        if secret != model.secret { model.secret = secret }
        model.restart()
    }
}
