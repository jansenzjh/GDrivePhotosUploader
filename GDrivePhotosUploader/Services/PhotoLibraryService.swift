import Foundation
import Photos
import UniformTypeIdentifiers

struct ExportedPhotoAsset: Sendable {
    let item: PhotoAssetItem
    let fileURL: URL
    let filename: String
    let mimeType: String
    let fileSize: Int64?
}

final class PhotoLibraryService {
    var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    func scanAssets() async throws -> [PhotoAssetItem] {
        let status = authorizationStatus
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryError.permissionDenied
        }

        return await Task.detached(priority: .userInitiated) {
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            fetchOptions.predicate = NSPredicate(
                format: "mediaType == %d || mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )

            let assets = PHAsset.fetchAssets(with: fetchOptions)
            var items: [PhotoAssetItem] = []
            items.reserveCapacity(assets.count)

            assets.enumerateObjects { asset, _, _ in
                guard let creationDate = asset.creationDate else {
                    return
                }

                let resource = PHAssetResource.assetResources(for: asset).preferredOriginalResource
                let filename = resource?.originalFilename ?? "\(asset.localIdentifier.safeFilename).dat"
                let fileExtension = (filename as NSString).pathExtension.lowercased()
                let fileSize = resource?.estimatedFileSize

                items.append(
                    PhotoAssetItem(
                        localIdentifier: asset.localIdentifier,
                        creationDate: creationDate,
                        mediaType: PhotoAssetMediaType(assetMediaType: asset.mediaType),
                        originalFilename: filename,
                        fileExtension: fileExtension,
                        estimatedFileSize: fileSize
                    )
                )
            }

            AppLogger.info("Photos scan found \(items.count) image/video assets")
            return items
        }.value
    }

    func exportOriginal(for item: PhotoAssetItem) async throws -> ExportedPhotoAsset {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [item.localIdentifier], options: nil)
        guard let asset = result.firstObject else {
            throw PhotoLibraryError.assetNotFound
        }

        guard let resource = PHAssetResource.assetResources(for: asset).preferredOriginalResource else {
            throw PhotoLibraryError.noOriginalResource
        }

        let filename = resource.originalFilename.isEmpty ? item.originalFilename : resource.originalFilename
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GDrivePhotosUploaderExports", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let destination = tempDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension((filename as NSString).pathExtension)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        let size = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
        return ExportedPhotoAsset(
            item: item,
            fileURL: destination,
            filename: item.driveUploadFilename,
            mimeType: resource.uniformTypeIdentifier.mimeTypeFallback(forExtension: item.fileExtension),
            fileSize: size?.int64Value ?? item.estimatedFileSize
        )
    }
}

enum PhotoLibraryError: LocalizedError {
    case permissionDenied
    case assetNotFound
    case noOriginalResource

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Photos permission is required before syncing."
        case .assetNotFound:
            "The Photos asset could not be found."
        case .noOriginalResource:
            "The original Photos resource could not be exported."
        }
    }
}

private extension Array where Element == PHAssetResource {
    var preferredOriginalResource: PHAssetResource? {
        first { $0.type == .photo || $0.type == .video || $0.type == .fullSizePhoto }
            ?? first
    }
}

private extension PHAssetResource {
    var estimatedFileSize: Int64? {
        value(forKey: "fileSize") as? Int64
    }
}

private extension String {
    var safeFilename: String {
        replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    func mimeTypeFallback(forExtension fileExtension: String) -> String {
        if let type = UTType(self), let mimeType = type.preferredMIMEType {
            return mimeType
        }

        if let type = UTType(filenameExtension: fileExtension), let mimeType = type.preferredMIMEType {
            return mimeType
        }

        switch fileExtension.lowercased() {
        case "heic":
            return "image/heic"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "mov":
            return "video/quicktime"
        case "mp4":
            return "video/mp4"
        default:
            return "application/octet-stream"
        }
    }
}

private extension PhotoAssetItem {
    var driveUploadFilename: String {
        let timestamp = Self.driveFilenameDateFormatter.string(from: creationDate)
        let ext = fileExtension.isEmpty ? originalFilename.pathExtensionFallback : fileExtension
        guard !ext.isEmpty else {
            return "\(timestamp)_iOS"
        }
        return "\(timestamp)_iOS.\(ext.lowercased())"
    }

    static let driveFilenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmssSSS"
        return formatter
    }()
}

private extension String {
    var pathExtensionFallback: String {
        (self as NSString).pathExtension
    }
}
