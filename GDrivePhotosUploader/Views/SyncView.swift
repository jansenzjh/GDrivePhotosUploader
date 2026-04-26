import Combine
import Photos
import SwiftUI

struct SyncView: View {
    @EnvironmentObject private var authService: GoogleAuthService
    @EnvironmentObject private var syncManager: SyncManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Photos Sync", systemImage: "photo.on.rectangle.angled")

            permissionSection
            dateFilterSection
            Divider()
            statusSection
            controls
            summarySection
            errorSection
        }
        .cardStyle()
        .overlay {
            if syncManager.phase == .scanning {
                scanningOverlay
            }
        }
    }

    private var scanningOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Checking Photos Library...")
                    .font(.headline)
                Text("This can take a moment for large libraries.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private var dateFilterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker(
                "Sync photos after",
                selection: $syncManager.syncStartDate,
                displayedComponents: .date
            )

            Text("Only photos and videos created on or after this date will be uploaded.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .disabled(syncManager.isSyncRunning)
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Photos Permission") {
                Text(syncManager.photoAuthorizationStatus.displayName)
                    .foregroundStyle(permissionColor)
            }

            if syncManager.photoAuthorizationStatus == .notDetermined {
                Button("Request Photos Access") {
                    Task {
                        await syncManager.requestPhotoAuthorization()
                    }
                }
                .buttonStyle(.bordered)
            } else if syncManager.photoAuthorizationStatus == .denied || syncManager.photoAuthorizationStatus == .restricted {
                Text("Enable Photos access in Settings before syncing.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if syncManager.photoAuthorizationStatus == .limited {
                Text("Limited access is supported. Only the selected photos/videos will be scanned.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Status", value: syncManager.phase.title)
            LabeledContent("Progress", value: "\(syncManager.uploadedCount) / \(syncManager.uploadTotalCount) uploaded")

            if let currentFilename = syncManager.currentFilename {
                LabeledContent("Current File") {
                    Text(currentFilename)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }

            ProgressView(value: Double(syncManager.uploadedCount), total: Double(max(syncManager.uploadTotalCount, 1)))
        }
    }

    private var controls: some View {
        HStack {
            Button("Sync") {
                syncManager.startSync()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!syncManager.canSync)

            if syncManager.phase == .paused {
                Button("Resume") {
                    syncManager.resumeSync()
                }
                .buttonStyle(.bordered)
            } else {
                Button("Pause") {
                    syncManager.pauseSync()
                }
                .buttonStyle(.bordered)
                .disabled(!syncManager.isSyncRunning)
            }

            Button("Cancel", role: .destructive) {
                syncManager.cancelSync()
            }
            .buttonStyle(.bordered)
            .disabled(!syncManager.isSyncRunning)
        }
    }

    private var summarySection: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                SummaryCell(title: "Found", value: syncManager.summary.totalAssetsFound)
                SummaryCell(title: "Skipped", value: syncManager.summary.alreadyUploaded)
            }
            GridRow {
                SummaryCell(title: "Uploaded", value: syncManager.summary.newlyUploaded)
                SummaryCell(title: "Failed", value: syncManager.summary.failed)
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if !syncManager.errors.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Latest Errors")
                    .font(.headline)

                ForEach(syncManager.errors.prefix(5), id: \.self) { error in
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var permissionColor: Color {
        switch syncManager.photoAuthorizationStatus {
        case .authorized, .limited:
            .green
        case .denied, .restricted:
            .red
        default:
            .secondary
        }
    }
}

private struct SummaryCell: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3.monospacedDigit())
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
