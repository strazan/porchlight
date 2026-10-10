import PorchlightCore
import SwiftUI

/// Adds or edits one server.
struct ServerEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    @State private var draft: ServerConfig
    @State private var commandLine: String
    @State private var env: [EnvVar]
    /// While adding, the name follows the command until the user types one.
    @State private var nameEdited: Bool

    struct EnvVar: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    init(server: ServerConfig, isNew: Bool) {
        self.isNew = isNew
        _draft = State(initialValue: server)
        _commandLine = State(initialValue: server.commandLineString)
        _env = State(initialValue: server.env.sorted { $0.key < $1.key }.map { EnvVar(key: $0.key, value: $0.value) })
        _nameEdited = State(initialValue: !isNew)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Command", text: $commandLine, prompt: Text("npx -y @modelcontextprotocol/server-filesystem ~/Documents"))
                        .font(.body.monospaced())
                        .onChange(of: commandLine) { _, line in
                            if !nameEdited { draft.name = ServerConfig.suggestedName(for: splitCommandLine(line)) }
                        }
                    TextField("Name", text: Binding(get: { draft.name }, set: {
                        draft.name = $0
                        nameEdited = true
                    }), prompt: Text("filesystem"))
                } footer: {
                    Text(nameError ?? "Runs with your login shell's PATH, so npx, uvx and Homebrew tools work. "
                        + "The name is used in this server's URL and to prefix its tools.")
                        .font(.caption)
                        .foregroundStyle(nameError == nil ? Color.secondary : Color.red)
                }

                Section("Environment") {
                    ForEach($env) { $variable in
                        HStack {
                            TextField("NAME", text: $variable.key)
                                .font(.body.monospaced())
                                .frame(maxWidth: 180)
                            SecureField("value", text: $variable.value)
                            Button {
                                env.removeAll { $0.id == variable.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                        .labelsHidden()
                    }
                    Button("Add Variable") { env.append(EnvVar(key: "", value: "")) }
                }

                Toggle("Enabled", isOn: $draft.enabled)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameError != nil || splitCommandLine(commandLine).isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 440)
    }

    private var nameError: String? {
        if draft.name.isEmpty { return nil } // nothing to complain about yet; Add stays disabled
        if !ServerConfig.isValidName(draft.name) { return "Use lowercase letters, digits and single hyphens." }
        if model.servers.contains(where: { $0.name == draft.name && $0.id != draft.id }) {
            return "Another server is already called \(draft.name)."
        }
        return nil
    }

    private func save() {
        guard !draft.name.isEmpty else { return }
        draft.commandLineString = commandLine
        draft.env = Dictionary(
            env.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        if isNew { model.add(draft) } else { model.update(draft) }
        dismiss()
    }
}
