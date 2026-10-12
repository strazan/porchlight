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
    @State private var editingTools = false
    @State private var confirmingRemove = false
    @State private var changingIcon = false

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
            VStack(alignment: .leading, spacing: 14) {
                SheetHeader(
                    title: isNew ? "Add Server" : "Edit \(draft.name)",
                    subtitle: draft.transport == .stdio
                        ? "A command Porchlight runs on this Mac."
                        : "A server that's already running on this Mac or your network, like Obsidian's."
                ) {
                    Button { changingIcon = true } label: {
                        ServerIcon(server: preview, size: 40)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "pencil.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.accentColor)
                                    .font(.system(size: 14))
                                    .offset(x: 4, y: 4)
                            }
                    }
                    .buttonStyle(.plain)
                    .help("Change icon")
                }
                Picker("Type", selection: $draft.transport) {
                    Text("Command").tag(ServerConfig.Transport.stdio)
                    Text("URL").tag(ServerConfig.Transport.http)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: draft.transport) { test = .idle }
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 4)

            Form {
                Section {
                    if draft.transport == .stdio {
                        TextField("Command", text: $commandLine, prompt: Text("npx -y @modelcontextprotocol/server-filesystem ~/Documents"), axis: .vertical)
                            .font(.body.monospaced())
                            .lineLimit(1...3)
                            .labelsHidden()
                            .onChange(of: commandLine) { _, line in
                                if !nameEdited { draft.name = ServerConfig.suggestedName(for: splitCommandLine(line)) }
                                test = .idle
                            }
                    } else {
                        TextField("URL", text: $draft.url, prompt: Text("http://127.0.0.1:27123/mcp/"))
                            .font(.body.monospaced())
                            .labelsHidden()
                            .onChange(of: draft.url) { test = .idle }
                        SecureField("API key", text: $apiKey, prompt: Text("Optional"))
                            .onChange(of: apiKey) { test = .idle }
                    }
                    TextField("Name", text: Binding(get: { draft.name }, set: {
                        draft.name = $0
                        nameEdited = true
                    }), prompt: Text(draft.transport == .stdio ? "From the command" : "Required"))
                } header: {
                    Text(draft.transport == .stdio ? "Command" : "URL")
                } footer: {
                    if let nameError {
                        Text(nameError).font(.caption).foregroundStyle(.red)
                    } else {
                        Footnote(draft.transport == .stdio
                            ? "Runs with your login shell's PATH, so npx, uvx and Homebrew tools work. Its tools appear as \(shownName)__tool."
                            : "The API key is sent as Authorization: Bearer <key>; pasting the whole header line works too. Its tools appear as \(shownName)__tool.")
                    }
                }

                if draft.transport == .http {
                    PairsSection(title: "Other Headers", items: $headers, namePrompt: "X-Api-Key", add: "Add Header", error: pairError)
                } else {
                    PairsSection(title: "Environment Variables", items: $env, namePrompt: "GITHUB_TOKEN", add: "Add Variable", error: pairError)
                }

                Section {
                    Picker("Tools", selection: $draft.toolPolicy.defaultPermission) {
                        ForEach(ToolPolicy.Default.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    LabeledContent(overridesSummary) {
                        Button("Per-Tool Settings…") { editingTools = true }
                            .disabled(!preview.isRunnable || pairError != nil)
                    }
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Permissions")
                } footer: {
                    Footnote(draft.toolPolicy.defaultPermission.explanation)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 8) {
                Button("Test Connection") { runTest() }
                    .disabled(!preview.isRunnable || test == .running || pairError != nil)
                testResult
                Spacer(minLength: 8)
                if !isNew {
                    Button("Remove…", role: .destructive) { confirmingRemove = true }
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameError != nil || pairError != nil || draft.name.isEmpty || !preview.isRunnable)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .sheet(isPresented: $editingTools) {
            ToolPermissionsView(config: preview, policy: $draft.toolPolicy)
        }
        .sheet(isPresented: $changingIcon) { ServerIconPicker(server: preview) }
        .confirmationDialog("Remove \(draft.name)?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) {
                model.remove([draft.id])
                dismiss()
            }
        } message: {
            Text("Apps lose access to its tools right away.")
        }
    }

    @ViewBuilder private var testResult: some View {
        switch test {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .passed(let summary):
            Label(summary, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .lineLimit(1)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(message)
                .textSelection(.enabled)
        }
    }

    private var shownName: String { draft.name.isEmpty ? "name" : draft.name }

    private var overridesSummary: String {
        let overrides = draft.toolPolicy.overrides
        if overrides.isEmpty { return "No exceptions" }
        return "\(counted(overrides.count, "tool")) set individually"
    }

    private var nameError: String? {
        if draft.name.isEmpty { return nil } // nothing to complain about yet; Add stays disabled
        if !ServerConfig.isValidName(draft.name) { return "Use lowercase letters, digits and single hyphens." }
        if model.servers.contains(where: { $0.name == draft.name && $0.id != draft.id }) {
            return "Another server is already called \(draft.name)."
        }
        return nil
    }

    private var pairError: String? {
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
                test = .passed("\(found.serverName) · \(counted(found.tools.count, "tool"))")
            case .failure(let error):
                test = .failed(UpstreamStatus.explain(error.message))
            }
        }
    }

    private func save() {
        guard !draft.name.isEmpty else { return }
        if isNew { model.add(preview) } else { model.update(preview) }
        dismiss()
    }
}

/// Name/value rows (environment variables or headers) with column headings.
private struct PairsSection: View {
    let title: String
    @Binding var items: [ServerEditor.Pair]
    let namePrompt: String
    let add: String
    let error: String?

    var body: some View {
        Section {
            if !items.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Text("Name")
                        Text("Value")
                        Color.clear.frame(width: 16, height: 1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach($items) { $item in
                        GridRow {
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
                                items.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    }
                }
            }
            Button {
                items.append(ServerEditor.Pair(name: "", value: ""))
            } label: {
                Label(add, systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Text(title)
        } footer: {
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

extension ToolPolicy.Default {
    var title: String {
        switch self {
        case .allowAll: "Always allow"
        case .askForChanges: "Ask before changes"
        case .askAll: "Always ask"
        }
    }

    var explanation: String {
        switch self {
        case .allowAll: "Apps can run any of its tools without asking."
        case .askForChanges: "Read-only tools run right away. Anything else asks on this Mac first."
        case .askAll: "Every tool call asks on this Mac first."
        }
    }
}
