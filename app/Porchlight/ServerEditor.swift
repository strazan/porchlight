import PorchlightCore
import SwiftUI

/// Adds or edits one server.
struct ServerEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    @State private var draft: ServerConfig
    @State private var commandLine: String
    @State private var env: [Pair]
    /// For URL servers: sent as `Authorization: Bearer <key>`.
    @State private var apiKey: String
    /// For URL servers: any headers besides the API key.
    @State private var headers: [Pair]
    /// While adding, the name follows the command until the user types one.
    @State private var nameEdited: Bool
    @State private var test: TestState = .idle

    struct Pair: Identifiable {
        let id = UUID()
        var name: String
        var value: String
    }

    enum TestState: Equatable {
        case idle
        case running
        case passed(String)
        case failed(String)
    }

    init(server: ServerConfig, isNew: Bool) {
        let server = server.repairingHeaders()
        self.isNew = isNew
        _draft = State(initialValue: server)
        _commandLine = State(initialValue: server.commandLineString)
        _env = State(initialValue: server.env.sorted { $0.key < $1.key }.map { Pair(name: $0.key, value: $0.value) })
        let token = server.bearerToken
        _apiKey = State(initialValue: token)
        // A bearer Authorization header is shown as the API key; anything else stays a header.
        _headers = State(initialValue: server.headers
            .filter { !(token.isEmpty == false && $0.key == "Authorization") }
            .sorted { $0.key < $1.key }
            .map { Pair(name: $0.key, value: $0.value) })
        _nameEdited = State(initialValue: !isNew)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Type", selection: $draft.transport) {
                    Text("Command").tag(ServerConfig.Transport.stdio)
                    Text("URL").tag(ServerConfig.Transport.http)
                }
                .pickerStyle(.segmented)
                .onChange(of: draft.transport) { test = .idle }

                Section {
                    if draft.transport == .stdio {
                        TextField("Command", text: $commandLine, prompt: Text("npx -y @modelcontextprotocol/server-filesystem ~/Documents"))
                            .font(.body.monospaced())
                            .onChange(of: commandLine) { _, line in
                                if !nameEdited { draft.name = ServerConfig.suggestedName(for: splitCommandLine(line)) }
                            }
                    } else {
                        TextField("URL", text: $draft.url, prompt: Text("http://127.0.0.1:27123/mcp/"))
                            .font(.body.monospaced())
                    }
                    TextField("Name", text: Binding(get: { draft.name }, set: {
                        draft.name = $0
                        nameEdited = true
                    }), prompt: Text(draft.transport == .stdio ? "filesystem" : "obsidian"))
                } footer: {
                    Text(nameError ?? footer)
                        .font(.caption)
                        .foregroundStyle(nameError == nil ? Color.secondary : Color.red)
                }

                if draft.transport == .http {
                    Section {
                        SecureField("API key", text: $apiKey, prompt: Text("Paste the key"))
                    } footer: {
                        Text("Sent as Authorization: Bearer <key>. Paste just the key; a whole header line like \"Authorization\": \"Bearer …\" works too. Leave empty if the server doesn't need one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    pairs(
                        "Other Headers", $headers,
                        namePrompt: "X-Api-Key", add: "Add Header",
                        footer: "Only if the server needs headers besides the API key."
                    )
                } else {
                    pairs(
                        "Environment Variables", $env,
                        namePrompt: "GITHUB_TOKEN", add: "Add Variable",
                        footer: "Passed to the command, e.g. API keys it reads from the environment."
                    )
                }

                Section {
                    Toggle("Enabled", isOn: $draft.enabled)
                    HStack(alignment: .firstTextBaseline) {
                        Button("Test Connection") { runTest() }
                            .disabled(!preview.isRunnable || test == .running || headerError != nil)
                        testResult
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameError != nil || headerError != nil || draft.name.isEmpty || !preview.isRunnable)
            }
            .padding()
        }
        .frame(width: 560, height: 560)
    }

    @ViewBuilder private var testResult: some View {
        switch test {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .passed(let summary):
            Label(summary, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private var footer: String {
        switch draft.transport {
        case .stdio:
            "Runs with your login shell's PATH, so npx, uvx and Homebrew tools work. The name is used in this server's URL and to prefix its tools."
        case .http:
            "A server that's already running on this Mac, like Obsidian's. The name is used in this server's URL and to prefix its tools."
        }
    }

    private func pairs(_ title: String, _ items: Binding<[Pair]>, namePrompt: String, add: String, footer: String) -> some View {
        Section {
            ForEach(items) { $item in
                HStack(alignment: .firstTextBaseline) {
                    TextField("Name", text: $item.name, prompt: Text(namePrompt))
                        .font(.body.monospaced())
                        .onChange(of: item.name) { _, name in
                            // A pasted "Name: value" line goes into both fields.
                            if !ServerConfig.isValidHeaderName(name), let header = ServerConfig.parseHeader(name) {
                                item.name = header.name
                                if item.value.isEmpty { item.value = header.value }
                            }
                        }
                    SecureField("Value", text: $item.value, prompt: Text("value"))
                    Button {
                        items.wrappedValue.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
            Button(add) { items.wrappedValue.append(Pair(name: "", value: "")) }
        } header: {
            Text(title)
        } footer: {
            Text(headerError ?? footer)
                .font(.caption)
                .foregroundStyle(headerError == nil ? Color.secondary : Color.red)
        }
    }

    private var nameError: String? {
        if draft.name.isEmpty { return nil } // nothing to complain about yet; Add stays disabled
        if !ServerConfig.isValidName(draft.name) { return "Use lowercase letters, digits and single hyphens." }
        if model.servers.contains(where: { $0.name == draft.name && $0.id != draft.id }) {
            return "Another server is already called \(draft.name)."
        }
        return nil
    }

    private var headerError: String? {
        let names = (draft.transport == .http ? headers : env).map(\.name).filter { !$0.isEmpty }
        if let bad = names.first(where: { !ServerConfig.isValidHeaderName($0) }) {
            return "“\(bad)” isn't a valid name: use letters, digits and hyphens, without spaces or colons."
        }
        return nil
    }

    /// The draft with the edited fields applied, for the active transport only.
    private var preview: ServerConfig {
        var config = draft
        let dictionary = { (items: [Pair]) in
            Dictionary(items.filter { !$0.name.isEmpty }.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
        }
        switch config.transport {
        case .stdio:
            config.commandLineString = commandLine
            config.env = dictionary(env)
            config.url = ""
            config.headers = [:]
        case .http:
            config.url = config.url.trimmingCharacters(in: .whitespaces)
            config.headers = dictionary(headers)
            config.bearerToken = apiKey
            config.command = ""
            config.args = []
            config.env = [:]
        }
        return config
    }

    private func runTest() {
        test = .running
        let config = preview
        Task {
            switch await model.probe(config) {
            case .success(let found):
                test = .passed("Connected to \(found.serverName) · \(found.toolCount) tool\(found.toolCount == 1 ? "" : "s")")
            case .failure(let error):
                test = .failed(error.message)
            }
        }
    }

    private func save() {
        guard !draft.name.isEmpty else { return }
        if isNew { model.add(preview) } else { model.update(preview) }
        dismiss()
    }
}
