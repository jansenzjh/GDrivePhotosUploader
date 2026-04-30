import Combine
import Foundation
import Photos

struct UploadThreadProgress: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable {
        case idle
        case waiting
        case uploading
        case completed
        case failed
    }

    let id: Int
    var completedCount: Int = 0
    var currentFilename: String?
    var status: Status = .idle

    var title: String {
        "Thread \(id)"
    }

    var detail: String {
        switch status {
        case .idle:
            "Idle"
        case .waiting:
            "Paused"
        case .uploading:
            currentFilename ?? "Uploading"
        case .completed:
            "Completed"
        case .failed:
            "Latest upload failed"
        }
    }
}

@MainActor
final class SyncManager: ObservableObject {
    static let minUploadThreadCount = 1
    static let maxUploadThreadCount = 10

    @Published private(set) var photoAuthorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published private(set) var phase: SyncPhase = .idle
    @Published private(set) var summary: SyncSummary = .empty
    @Published private(set) var uploadedCount = 0
    @Published private(set) var uploadTotalCount = 0
    @Published private(set) var currentFilename: String?
    @Published private(set) var threadProgress: [UploadThreadProgress] = []
    @Published private(set) var errors: [String] = []
    @Published var syncStartDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @Published private(set) var uploadThreadCount: Int

    private let authService: GoogleAuthService
    private let photoLibraryService: PhotoLibraryService
    private let driveService: GoogleDriveService
    private let stateStore: UploadStateStore
    private var syncTask: Task<Void, Never>?
    private var isPauseRequested = false

    private static let uploadThreadCountDefaultsKey = "uploadThreadCount"

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
        let savedThreadCount = UserDefaults.standard.integer(forKey: Self.uploadThreadCountDefaultsKey)
        self.uploadThreadCount = Self.clampedUploadThreadCount(savedThreadCount == 0 ? Self.minUploadThreadCount : savedThreadCount)
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

    func setUploadThreadCount(_ count: Int) {
        let clampedCount = Self.clampedUploadThreadCount(count)
        guard uploadThreadCount != clampedCount else {
            return
        }

        uploadThreadCount = clampedCount
        UserDefaults.standard.set(clampedCount, forKey: Self.uploadThreadCountDefaultsKey)
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
            threadProgress = []
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

            let workerCount = pendingAssets.isEmpty ? 0 : min(uploadThreadCount, pendingAssets.count)
            resetThreadProgress(count: workerCount)
            AppLogger.info("Sync starting from \(syncStartDate): \(eligibleAssets.count) eligible assets, \(summary.alreadyUploaded) already uploaded, \(pendingAssets.count) pending, \(workerCount) upload thread(s)")

            if !pendingAssets.isEmpty {
                let folderIDs = try await prepareFolderIDs(for: pendingAssets, token: token)
                try Task.checkCancellation()
                try await runUploadWorkers(
                    assets: pendingAssets,
                    folderIDs: folderIDs,
                    token: token,
                    workerCount: workerCount
                )
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

    private func runUploadWorkers(
        assets: [PhotoAssetItem],
        folderIDs: [String: String],
        token: String,
        workerCount: Int
    ) async throws {
        let queue = UploadWorkQueue(assets: assets)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for workerID in 1...workerCount {
                group.addTask { [weak self] in
                    try await self?.runUploadWorker(
                        id: workerID,
                        queue: queue,
                        folderIDs: folderIDs,
                        token: token
                    )
                }
            }

            try await group.waitForAll()
        }
    }

    private func runUploadWorker(
        id: Int,
        queue: UploadWorkQueue,
        folderIDs: [String: String],
        token: String
    ) async throws {
        while true {
            try Task.checkCancellation()
            await waitIfPaused(workerID: id)
            try Task.checkCancellation()

            guard let asset = await queue.next() else {
                updateThreadProgress(id: id, status: .completed, currentFilename: nil)
                return
            }

            updateThreadProgress(id: id, status: .uploading, currentFilename: asset.originalFilename)
            do {
                let outcome = try await RetryPolicy.upload.run {
                    try await self.upload(asset: asset, folderIDs: folderIDs, token: token)
                }
                switch outcome {
                case .uploaded:
                    summary.newlyUploaded += 1
                case .duplicate:
                    summary.alreadyUploaded += 1
                }
                uploadedCount += 1
                incrementThreadCompletedCount(id: id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                summary.failed += 1
                uploadedCount += 1
                incrementThreadCompletedCount(id: id)
                updateThreadProgress(id: id, status: .failed, currentFilename: asset.originalFilename)
                let message = "\(asset.originalFilename): \(error.localizedDescription)"
                appendError(message)
                AppLogger.error("Upload failed for \(message)")
            }
        }
    }

    private func prepareFolderIDs(for assets: [PhotoAssetItem], token: String) async throws -> [String: String] {
        var folderIDs: [String: String] = [:]

        for asset in assets {
            let month = asset.driveMonth
            guard folderIDs[month.key] == nil else {
                continue
            }

            try Task.checkCancellation()
            let folderID = try await driveService.findOrCreateFolderPath(
                rootName: AppConfiguration.driveRootFolderName,
                year: month.year,
                month: month.month,
                token: token,
                stateStore: stateStore
            )
            folderIDs[month.key] = folderID
        }

        return folderIDs
    }

    private func upload(asset: PhotoAssetItem, folderIDs: [String: String], token: String) async throws -> UploadOutcome {
        let exported = try await photoLibraryService.exportOriginal(for: asset)
        defer {
            try? FileManager.default.removeItem(at: exported.fileURL)
        }

        let month = asset.driveMonth
        guard let folderID = folderIDs[month.key] else {
            throw SyncError.missingPreparedFolder(month.key)
        }

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

        AppLogger.info("Uploading \(exported.filename) to /\(AppConfiguration.driveRootFolderName)/\(month.year)/\(month.month)")
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

    private func waitIfPaused(workerID: Int) async {
        var didMarkWaiting = false
        while isPauseRequested && !Task.isCancelled {
            if !didMarkWaiting {
                updateThreadProgress(id: workerID, status: .waiting, currentFilename: nil)
                didMarkWaiting = true
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func resetThreadProgress(count: Int) {
        guard count > 0 else {
            threadProgress = []
            updateCurrentFilename()
            return
        }

        threadProgress = (1...count).map { UploadThreadProgress(id: $0) }
        updateCurrentFilename()
    }

    private func updateThreadProgress(id: Int, status: UploadThreadProgress.Status, currentFilename: String?) {
        guard let index = threadProgress.firstIndex(where: { $0.id == id }) else {
            return
        }

        threadProgress[index].status = status
        threadProgress[index].currentFilename = currentFilename
        updateCurrentFilename()
    }

    private func incrementThreadCompletedCount(id: Int) {
        guard let index = threadProgress.firstIndex(where: { $0.id == id }) else {
            return
        }

        threadProgress[index].completedCount += 1
        updateCurrentFilename()
    }

    private func updateCurrentFilename() {
        let activeThreads = threadProgress.filter { $0.status == .uploading && $0.currentFilename != nil }
        if activeThreads.count > 1 {
            currentFilename = "\(activeThreads.count) files uploading"
        } else {
            currentFilename = activeThreads.first?.currentFilename
        }
    }

    private func appendError(_ message: String) {
        errors.insert(message, at: 0)
        if errors.count > 20 {
            errors.removeLast(errors.count - 20)
        }
    }

    private static func clampedUploadThreadCount(_ count: Int) -> Int {
        min(max(count, minUploadThreadCount), maxUploadThreadCount)
    }
}

private actor UploadWorkQueue {
    private let assets: [PhotoAssetItem]
    private var nextIndex = 0

    init(assets: [PhotoAssetItem]) {
        self.assets = assets
    }

    func next() -> PhotoAssetItem? {
        guard nextIndex < assets.count else {
            return nil
        }

        let asset = assets[nextIndex]
        nextIndex += 1
        return asset
    }
}

private enum SyncError: LocalizedError {
    case missingPreparedFolder(String)

    var errorDescription: String? {
        switch self {
        case let .missingPreparedFolder(folder):
            "Prepared Drive folder was missing for \(folder)."
        }
    }
}

private struct DriveMonth: Hashable, Sendable {
    let year: String
    let month: String

    var key: String {
        "\(year)/\(month)"
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

private extension PhotoAssetItem {
    var driveMonth: DriveMonth {
        let components = Calendar.current.dateComponents([.year, .month], from: creationDate)
        return DriveMonth(
            year: String(format: "%04d", components.year ?? 1970),
            month: String(format: "%02d", components.month ?? 1)
        )
    }
}
