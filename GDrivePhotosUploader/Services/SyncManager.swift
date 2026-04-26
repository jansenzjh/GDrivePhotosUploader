import Combine
import Foundation
import Photos

@MainActor
final class SyncManager: ObservableObject {
    @Published private(set) var photoAuthorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published private(set) var phase: SyncPhase = .idle
    @Published private(set) var summary: SyncSummary = .empty
    @Published private(set) var uploadedCount = 0
    @Published private(set) var uploadTotalCount = 0
    @Published private(set) var currentFilename: String?
    @Published private(set) var errors: [String] = []
    @Published var syncStartDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()

    private let authService: GoogleAuthService
    private let photoLibraryService: PhotoLibraryService
    private let driveService: GoogleDriveService
    private let stateStore: UploadStateStore
    private var syncTask: Task<Void, Never>?
    private var isPauseRequested = false

    private enum UploadOutcome {
        case uploaded
        case duplicate
    }

    init(
        authService: GoogleAuthService,
        photoLibraryService: PhotoLibraryService,
        driveService: GoogleDriveService,
        stateStore: UploadStateStore
    ) {
        self.authService = authService
        self.photoLibraryService = photoLibraryService
        self.driveService = driveService
        self.stateStore = stateStore
        self.photoAuthorizationStatus = photoLibraryService.authorizationStatus
    }

    var canSync: Bool {
        authService.isSignedIn && (photoAuthorizationStatus == .authorized || photoAuthorizationStatus == .limited) && !isSyncRunning
    }

    var isSyncRunning: Bool {
        phase == .scanning || phase == .syncing || phase == .paused || phase == .cancelling
    }

    func refreshPhotoAuthorization() async {
        photoAuthorizationStatus = photoLibraryService.authorizationStatus
    }

    func requestPhotoAuthorization() async {
        photoAuthorizationStatus = await photoLibraryService.requestAuthorization()
        AppLogger.info("Photos authorization status: \(photoAuthorizationStatus.displayName)")
    }

    func startSync() {
        guard syncTask == nil else {
            return
        }

        syncTask = Task { [weak self] in
            await self?.runSync()
        }
    }

    func cancelSync() {
        phase = .cancelling
        syncTask?.cancel()
        syncTask = nil
    }

    func pauseSync() {
        guard isSyncRunning else {
            return
        }

        isPauseRequested = true
        phase = .paused
    }

    func resumeSync() {
        guard phase == .paused else {
            return
        }

        isPauseRequested = false
        phase = .syncing
    }

    private func runSync() async {
        defer {
            syncTask = nil
            currentFilename = nil
            isPauseRequested = false
        }

        guard authService.isSignedIn else {
            appendError("Sign in with Google before syncing.")
            phase = .failed("Google login required")
            return
        }

        guard photoAuthorizationStatus == .authorized || photoAuthorizationStatus == .limited else {
            appendError("Photos permission is required before syncing.")
            phase = .failed("Photos permission required")
            return
        }

        do {
            phase = .scanning
            summary = .empty
            uploadedCount = 0
            uploadTotalCount = 0
            errors = []

            let token = try await authService.validAccessToken()
            let assets = try await photoLibraryService.scanAssets()
            let eligibleAssets = assets.filter { $0.creationDate >= syncStartDate.startOfDay }
            let uploadedIDs = try await stateStore.allUploadedAssetIDs()
            let pendingAssets = eligibleAssets.filter { !uploadedIDs.contains($0.localIdentifier) }

            summary.totalAssetsFound = eligibleAssets.count
            summary.alreadyUploaded = eligibleAssets.count - pendingAssets.count
            uploadTotalCount = pendingAssets.count
            phase = .syncing

            AppLogger.info("Sync starting from \(syncStartDate): \(eligibleAssets.count) eligible assets, \(summary.alreadyUploaded) already uploaded, \(pendingAssets.count) pending")

            for asset in pendingAssets {
                try Task.checkCancellation()
                await waitIfPaused()
                try Task.checkCancellation()

                currentFilename = asset.originalFilename
                do {
                    let outcome = try await RetryPolicy.upload.run {
                        try await self.upload(asset: asset, token: token)
                    }
                    switch outcome {
                    case .uploaded:
                        summary.newlyUploaded += 1
                    case .duplicate:
                        summary.alreadyUploaded += 1
                    }
                    uploadedCount += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    summary.failed += 1
                    let message = "\(asset.originalFilename): \(error.localizedDescription)"
                    appendError(message)
                    AppLogger.error("Upload failed for \(message)")
                }
            }

            phase = .completed
            AppLogger.info("Sync completed: \(summary.newlyUploaded) uploaded, \(summary.failed) failed")
        } catch is CancellationError {
            phase = .idle
            AppLogger.info("Sync cancelled")
        } catch {
            appendError(error.localizedDescription)
            phase = .failed(error.localizedDescription)
            AppLogger.error("Sync failed: \(error.localizedDescription)")
        }
    }

    private func upload(asset: PhotoAssetItem, token: String) async throws -> UploadOutcome {
        let exported = try await photoLibraryService.exportOriginal(for: asset)
        defer {
            try? FileManager.default.removeItem(at: exported.fileURL)
        }

        let components = Calendar.current.dateComponents([.year, .month], from: asset.creationDate)
        let year = String(format: "%04d", components.year ?? 1970)
        let month = String(format: "%02d", components.month ?? 1)

        let folderID = try await driveService.findOrCreateFolderPath(
            rootName: AppConfiguration.driveRootFolderName,
            year: year,
            month: month,
            token: token,
            stateStore: stateStore
        )

        if let existingFile = try await driveService.findFile(name: exported.filename, parentFolderID: folderID, token: token) {
            AppLogger.warning("Duplicate Drive filename found, skipping upload: \(exported.filename) already exists as Drive file \(existingFile.id)")
            let record = UploadRecord(
                assetLocalIdentifier: asset.localIdentifier,
                driveFileId: existingFile.id,
                originalFilename: exported.filename,
                creationDate: asset.creationDate,
                uploadedAt: Date(),
                fileSize: exported.fileSize,
                mediaType: asset.mediaType
            )
            try await stateStore.saveUploadRecord(record)
            return .duplicate
        }

        AppLogger.info("Uploading \(exported.filename) to /\(AppConfiguration.driveRootFolderName)/\(year)/\(month)")
        let driveFile = try await driveService.uploadFile(exported, parentFolderID: folderID, token: token)
        let record = UploadRecord(
            assetLocalIdentifier: asset.localIdentifier,
            driveFileId: driveFile.id,
            originalFilename: exported.filename,
            creationDate: asset.creationDate,
            uploadedAt: Date(),
            fileSize: exported.fileSize,
            mediaType: asset.mediaType
        )
        try await stateStore.saveUploadRecord(record)
        AppLogger.info("Upload succeeded for \(exported.filename) as Drive file \(driveFile.id)")
        return .uploaded
    }

    private func waitIfPaused() async {
        while isPauseRequested && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func appendError(_ message: String) {
        errors.insert(message, at: 0)
        if errors.count > 20 {
            errors.removeLast(errors.count - 20)
        }
    }
}

extension PHAuthorizationStatus {
    var displayName: String {
        switch self {
        case .notDetermined:
            "Not Determined"
        case .restricted:
            "Restricted"
        case .denied:
            "Denied"
        case .authorized:
            "Full Access"
        case .limited:
            "Limited Access"
        @unknown default:
            "Unknown"
        }
    }
}

private extension Date {
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }
}
