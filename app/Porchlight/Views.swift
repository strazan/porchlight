import AppKit
import SwiftUI

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Porchlight").font(.headline)
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!model.isConfigured)
            }

            if !model.isConfigured {
                Text("Add your relay URL and secret in Settings to get started.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Divider()
                EndpointRow(label: "All servers", url: model.endpoint)
                EndpointRow(label: model.serverName, url: model.serverEndpoint)
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.serverName).font(.callout.weight(.medium))
                        Text(model.serverCommand)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }

            Divider()
            HStack {
                Button("Settings…") { show("settings") }
                Button("Logs") { show("logs") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
    }

    private var statusColor: Color {
        switch model.state {
        case .off: .gray
        case .starting, .relay(.connecting): .yellow
        case .relay(.connected): .green
        case .relay(.disconnected): .red
        }
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }
}

private struct EndpointRow: View {
    let label: String
    let url: String
    @State private var copied = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(url).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy URL")
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var relayURL = ""
    @State private var secret = ""
    @State private var serverName = ""
    @State private var serverCommand = ""

    var body: some View {
        Form {
            Section("Relay") {
                TextField("URL", text: $relayURL, prompt: Text("https://porchlight-relay.you.workers.dev"))
                SecureField("Secret", text: $secret, prompt: Text("AGENT_SECRET"))
            }
            Section {
                TextField("Name", text: $serverName, prompt: Text("everything"))
                TextField("Command", text: $serverCommand, prompt: Text("npx -y @modelcontextprotocol/server-everything"))
                    .font(.body.monospaced())
            } header: {
                Text("Server")
            } footer: {
                Text("Runs with your login shell's PATH, so npx, uvx and Homebrew tools work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save & Connect") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(relayURL.isEmpty || secret.isEmpty || serverCommand.isEmpty)
            }
            .padding()
        }
        .frame(width: 480)
        .onAppear {
            relayURL = model.relayURL
            secret = model.secret
            serverName = model.serverName
            serverCommand = model.serverCommand
        }
    }

    private func save() {
        model.relayURL = relayURL
        if secret != model.secret { model.secret = secret }
        model.serverName = serverName.isEmpty ? "default" : serverName
        model.serverCommand = serverCommand
        model.restart()
        dismiss()
    }
}

struct LogsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.logs) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(line.date, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.secondary)
                            Text(line.text).textSelection(.enabled)
                        }
                        .font(.caption.monospaced())
                        .id(line.id)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.logs.last?.id) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .toolbar {
            Button("Copy") {
                let text = model.logs.map(\.text).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            Button("Clear") { model.clearLogs() }
        }
        .frame(minWidth: 560, minHeight: 320)
    }
}
