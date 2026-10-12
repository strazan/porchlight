import PorchlightCore
import SwiftUI

/// Which servers one app may use.
struct AccessEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let app: AppModel.ConnectedApp
    @State private var access: Set<String>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "What can \(app.latest.clientName) use?", subtitle: "It won't see servers you leave out.") {
                AppIcon(clientID: app.id, name: app.latest.clientName, size: 32)
            }
            ServerAccessPicker(servers: model.servers.map(\.name), selection: $access)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setAccess(clientID: app.id, servers: access)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { access = model.access(for: app.id) }
    }
}
