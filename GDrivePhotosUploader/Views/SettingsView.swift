import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var syncManager: SyncManager
    @State private var isShowingClearLogConfirmation = false
    @State private var logStatus: String?

    var body: some View {
        List {
            Section("Performance") {
                Stepper(
                    value: Binding(
                        get: { syncManager.uploadThreadCount },
                        set: { syncManager.setUploadThreadCount($0) }
                    ),
                    in: SyncManager.minUploadThreadCount...SyncManager.maxUploadThreadCount
                ) {
                    LabeledContent("Upload Threads", value: "\(syncManager.uploadThreadCount)")
                }
                .disabled(syncManager.isSyncRunning)

                Text("Higher thread counts upload more files at the same time and can drain battery faster.")
                    .foregroundStyle(.secondary)
            }

            Section("Logs") {
                if let logStatus {
                    Text(logStatus)
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    LogViewerView()
                } label: {
                    Label("View Warnings & Errors", systemImage: "exclamationmark.triangle")
                }

                Button(role: .destructive) {
                    isShowingClearLogConfirmation = true
                } label: {
                    Label("Clear App Log", systemImage: "trash")
                }

                LabeledContent("Log File") {
                    Text(AppLogger.reviewLogFileURL.lastPathComponent)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sync") {
                Text("Drive filename duplicates are logged as warnings and skipped to avoid re-uploading after reinstall.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog(
            "Clear app log?",
            isPresented: $isShowingClearLogConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Log", role: .destructive) {
                AppLogger.clearLog()
                logStatus = "Log cleared."
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the local log text. It does not affect uploaded photos or sync records.")
        }
    }
}

#Preview {
    let authService = GoogleAuthService()
    NavigationStack {
        SettingsView()
    }
    .environmentObject(
        SyncManager(
            authService: authService,
            photoLibraryService: PhotoLibraryService(),
            driveService: GoogleDriveService(),
            stateStore: UploadStateStore()
        )
    )
}
