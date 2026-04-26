import Foundation

struct UploadRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String { assetLocalIdentifier }

    let assetLocalIdentifier: String
    let driveFileId: String
    let originalFilename: String
    let creationDate: Date
    let uploadedAt: Date
    let fileSize: Int64?
    let mediaType: PhotoAssetMediaType
}

struct FolderCacheRecord: Codable, Hashable, Sendable {
    let path: String
    let folderId: String
    let updatedAt: Date
}
