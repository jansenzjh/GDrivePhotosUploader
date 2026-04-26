import Foundation

enum AppConfiguration {
    static let googleClientID = "PASTE_GOOGLE_IOS_CLIENT_ID_HERE"
    static let driveScope = "https://www.googleapis.com/auth/drive.file"
    static let driveRootFolderName = "iPhone Photos"
    static let multipartUploadThresholdBytes: Int64 = 8 * 1024 * 1024

    static var isGoogleClientIDConfigured: Bool {
        !googleClientID.isEmpty && !googleClientID.contains("PASTE_")
    }
}
