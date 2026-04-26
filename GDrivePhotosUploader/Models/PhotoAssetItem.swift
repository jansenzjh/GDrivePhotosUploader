import Foundation
import Photos

enum PhotoAssetMediaType: String, Codable, Sendable {
    case image
    case video
    case unknown

    init(assetMediaType: PHAssetMediaType) {
        switch assetMediaType {
        case .image:
            self = .image
        case .video:
            self = .video
        default:
            self = .unknown
        }
    }
}

struct PhotoAssetItem: Identifiable, Codable, Hashable, Sendable {
    var id: String { localIdentifier }

    let localIdentifier: String
    let creationDate: Date
    let mediaType: PhotoAssetMediaType
    let originalFilename: String
    let fileExtension: String
    let estimatedFileSize: Int64?
}
