import Foundation

enum AppConfiguration {
    static var googleClientID: String {
        Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? ""
    }
    static let driveScope = "https://www.googleapis.com/auth/drive.file"
    static let driveRootFolderName = "iPhone Photos"
    static let multipartUploadThresholdBytes: Int64 = 8 * 1024 * 1024

    static var isGoogleClientIDConfigured: Bool {
        !googleClientID.isEmpty && !googleClientID.contains("PASTE_")
    }
}
