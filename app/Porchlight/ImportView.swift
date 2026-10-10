import PorchlightCore
import SwiftUI

/// Picks servers to import from Claude Desktop, Claude Code and Cursor.
struct ImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ImportCandidate] = []
    @State private var selected: Set<ImportCandidate.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            if candidates.isEmpty {
                ContentUnavailableView(
                    "Nothing to Import",
                    systemImage: "tray",
                    description: Text("No MCP servers were found in Claude Desktop, Claude Code or Cursor.")
                )
            } else {
                List {
                    ForEach(ImportCandidate.Source.allCases, id: \.self) { source in
                        let items = candidates.filter { $0.source == source }
                        if !items.isEmpty {
                            Section(source.rawValue) {
                                ForEach(items) { candidate in row(candidate) }
                            }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(selected.isEmpty ? "Import" : "Import \(selected.count)") {
                    model.importServers(candidates.filter { selected.contains($0.id) }.compactMap(\.config))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
            .padding()
        }
        .frame(width: 560, height: 440)
        .onAppear(perform: load)
    }

    private func row(_ candidate: ImportCandidate) -> some View {
        let alreadyAdded = candidate.config.map(model.hasServer(like:)) ?? false
        return Toggle(isOn: Binding(
            get: { selected.contains(candidate.id) },
            set: { on in
                if on { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(candidate.originalName).font(.body.weight(.medium))
                    if let scope = candidate.scope {
                        Text(scope).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                if let config = candidate.config {
                    Text(alreadyAdded ? "Already added" : config.commandLineString)
                        .font(alreadyAdded ? .caption : .caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let reason = candidate.unsupportedReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(candidate.config == nil || alreadyAdded)
    }

    private func load() {
        candidates = ConfigImporter.candidates()
        // Preselect everything new, once per distinct command (the same server is often
        // configured in several apps).
        var seen: [ServerConfig] = []
        for candidate in candidates {
            guard let config = candidate.config, !model.hasServer(like: config),
                  !seen.contains(where: { $0.commandLine == config.commandLine && $0.env == config.env })
            else { continue }
            seen.append(config)
            selected.insert(candidate.id)
        }
    }
}
