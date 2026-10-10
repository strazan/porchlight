import AppKit
import SwiftUI

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
                            Text(line.server ?? "porchlight")
                                .foregroundStyle(line.server == nil ? .secondary : .primary)
                                .frame(width: 110, alignment: .leading)
                                .lineLimit(1)
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
                let text = model.logs.map { "[\($0.server ?? "porchlight")] \($0.text)" }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            Button("Clear") { model.clearLogs() }
        }
        .frame(minWidth: 640, minHeight: 320)
    }
}
