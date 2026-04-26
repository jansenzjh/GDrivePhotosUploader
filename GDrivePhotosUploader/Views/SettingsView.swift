import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            Section("Logs") {
                NavigationLink {
                    LogViewerView()
                } label: {
                    Label("View App Log", systemImage: "doc.text.magnifyingglass")
                }

                LabeledContent("Log File") {
                    Text(AppLogger.logFileURL.lastPathComponent)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sync") {
                Text("Drive filename duplicates are logged as warnings and skipped to avoid re-uploading after reinstall.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
