import Foundation

actor UploadStateStore {
    private struct StateFile: Codable {
        var uploadedAssets: [String: UploadRecord] = [:]
        var folderCache: [String: FolderCacheRecord] = [:]
    }

    private let fileURL: URL
    private var state: StateFile?

    init(fileManager: FileManager = .default) {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GDrivePhotosUploader", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("upload-state.json")
    }

    func allUploadedAssetIDs() async throws -> Set<String> {
        let state = try loadState()
        return Set(state.uploadedAssets.keys)
    }

    func record(for assetLocalIdentifier: String) async throws -> UploadRecord? {
        try loadState().uploadedAssets[assetLocalIdentifier]
    }

    func saveUploadRecord(_ record: UploadRecord) async throws {
        var state = try loadState()
        state.uploadedAssets[record.assetLocalIdentifier] = record
        try saveState(state)
        AppLogger.info("Saved upload record for \(record.originalFilename)")
    }

    func cachedFolderID(for path: String) async throws -> String? {
        try loadState().folderCache[path]?.folderId
    }

    func saveFolderID(_ folderId: String, for path: String) async throws {
        var state = try loadState()
        state.folderCache[path] = FolderCacheRecord(path: path, folderId: folderId, updatedAt: Date())
        try saveState(state)
    }

    private func loadState() throws -> StateFile {
        if let state {
            return state
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = StateFile()
            state = empty
            return empty
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StateFile.self, from: data)
        state = decoded
        return decoded
    }

    private func saveState(_ newState: StateFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(newState)
        try data.write(to: fileURL, options: [.atomic])
        state = newState
    }
}
