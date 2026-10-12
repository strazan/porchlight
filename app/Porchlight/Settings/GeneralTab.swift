import PorchlightCore
import SwiftUI

/// Login, sleep and icons, and about Porchlight.
struct GeneralTab: View {
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
                LabeledContent("Version", value: Porchlight.version)
                if let source = URL(string: "https://github.com/strazan/porchlight") {
                    LabeledContent("Source code") {
                        Link("github.com/strazan/porchlight", destination: source)
                    }
                }
                LabeledContent("License", value: "MIT")
            }
        }
        .formStyle(.grouped)
    }
}
