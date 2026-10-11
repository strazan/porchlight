import AppKit
import PorchlightCore
import SwiftUI
import UniformTypeIdentifiers

/// An app's icon: its website's icon or a custom image, else its initial.
struct AppIcon: View {
    @Environment(AppModel.self) private var model
    let clientID: String
    let name: String
    var size: CGFloat = 28

    var body: some View {
        let key = IconStore.key(app: clientID)
        Group {
            if !clientID.isEmpty, let image = model.icons.images[key] {
                IconImage(image: image, size: size)
            } else {
                AppAvatar(name: name, size: size)
            }
        }
        .task(id: "\(key)|\(model.icons.revision)") {
            guard !clientID.isEmpty else { return }
            await model.icons.load(key: key, defaultWebsite: model.defaultIconWebsite(forApp: clientID))
        }
    }
}

/// A server's icon (its project's icon, a custom image, or a symbol), optionally with its
/// status dot in the corner.
struct ServerIcon: View {
    @Environment(AppModel.self) private var model
    let server: ServerConfig
    var size: CGFloat = 28
    var status: UpstreamStatus?

    var body: some View {
        let key = IconStore.key(server: server)
        Group {
            if let image = model.icons.images[key] {
                IconImage(image: image, size: size)
            } else {
                Image(systemName: ServerIconHint.symbol(for: server))
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.24))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let status {
                StatusDot(status: status, diameter: size < 24 ? 6 : 8)
                    .padding(1.5)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                    .offset(x: 3, y: 3)
            }
        }
        .task(id: "\(key)|\(model.icons.revision)|\(server.name)|\(server.url)") {
            await model.icons.load(key: key, defaultWebsite: ServerIconHint.domain(for: server), defaultApp: ServerIconHint.macApp(for: server))
        }
    }
}

private struct IconImage: View {
    let image: NSImage
    let size: CGFloat

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
    }
}

/// Chooses where an app's or server's icon comes from.
struct IconPicker<Preview: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let key: String
    let title: String
    /// Where the icon comes from by default, if anywhere.
    let defaultWebsite: String?
    /// What "Plain" means here: "Initial" for apps, "Symbol" for servers.
    let plainLabel: String
    @ViewBuilder var preview: Preview

    private enum Choice: Hashable {
        case automatic, website, image, plain
    }

    @State private var choice: Choice = .automatic
    @State private var website = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                preview
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    Text("Shown in Porchlight only.").font(.callout).foregroundStyle(.secondary)
                }
            }

            Picker("Icon", selection: $choice) {
                Text(defaultWebsite.map { "Automatic (from \($0))" } ?? "Automatic").tag(Choice.automatic)
                Text("From a website").tag(Choice.website)
                Text("Custom image").tag(Choice.image)
                Text(plainLabel).tag(Choice.plain)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if choice == .website {
                TextField("Website", text: $website, prompt: Text("obsidian.md"))
                    .textFieldStyle(.roundedBorder)
            }
            if choice == .image {
                Button("Choose Image…", action: chooseImage)
            }
            if !model.icons.fetchFromWebsites, choice == .automatic || choice == .website {
                Label("Icons from websites are turned off in Settings → General.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Done") {
                    apply()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(choice == .website && website.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear(perform: load)
    }

    private func load() {
        switch model.icons.override(for: key) {
        case .website(let site)?:
            choice = .website
            website = site
        case .image?: choice = .image
        case .plain?: choice = .plain
        case nil: choice = .automatic
        }
    }

    private func apply() {
        switch choice {
        case .automatic: model.icons.setOverride(nil, for: key)
        case .website: model.icons.setOverride(.website(website.trimmingCharacters(in: .whitespaces)), for: key)
        case .image: break // applied when the image was chosen
        case .plain: model.icons.setOverride(.plain, for: key)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.icons.setCustomImage(from: url, for: key)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The icon picker for a server.
struct ServerIconPicker: View {
    let server: ServerConfig

    var body: some View {
        IconPicker(
            key: IconStore.key(server: server),
            title: "Icon for \(server.name.isEmpty ? "this server" : server.name)",
            defaultWebsite: ServerIconHint.domain(for: server),
            plainLabel: "Symbol"
        ) {
            ServerIcon(server: server, size: 48)
        }
    }
}
