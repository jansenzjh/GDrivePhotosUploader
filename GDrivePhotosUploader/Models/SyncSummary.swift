import Foundation

struct SyncSummary: Codable, Equatable, Sendable {
    var totalAssetsFound = 0
    var alreadyUploaded = 0
    var newlyUploaded = 0
    var failed = 0

    static let empty = SyncSummary()
}

enum SyncPhase: Equatable, Sendable {
    case idle
    case scanning
    case syncing
    case paused
    case cancelling
    case completed
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            "Idle"
        case .scanning:
            "Scanning Photos Library"
        case .syncing:
            "Syncing"
        case .paused:
            "Paused"
        case .cancelling:
            "Cancelling"
        case .completed:
            "Completed"
        case .failed:
            "Failed"
        }
    }
}
