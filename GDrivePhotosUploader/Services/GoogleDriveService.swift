import Foundation

final class GoogleDriveService {
    private let session: URLSession
    private let rateLimiter: GoogleDriveRateLimiter
    private let baseFilesURL = URL(string: "https://www.googleapis.com/drive/v3/files")!
    private let uploadFilesURL = URL(string: "https://www.googleapis.com/upload/drive/v3/files")!

    init(
        session: URLSession = .shared,
        rateLimiter: GoogleDriveRateLimiter = GoogleDriveRateLimiter(maxRequestsPerSecond: AppConfiguration.driveMaxRequestsPerSecond)
    ) {
        self.session = session
        self.rateLimiter = rateLimiter
    }

    func findOrCreateFolderPath(
        rootName: String,
        year: String,
        month: String,
        token: String,
        stateStore: UploadStateStore
    ) async throws -> String {
        let rootID = try await findOrCreateFolder(name: rootName, parentID: "root", path: "/\(rootName)", token: token, stateStore: stateStore)
        let yearID = try await findOrCreateFolder(name: year, parentID: rootID, path: "/\(rootName)/\(year)", token: token, stateStore: stateStore)
        return try await findOrCreateFolder(name: month, parentID: yearID, path: "/\(rootName)/\(year)/\(month)", token: token, stateStore: stateStore)
    }

    func uploadFile(_ exportedAsset: ExportedPhotoAsset, parentFolderID: String, token: String) async throws -> DriveFile {
        let size = exportedAsset.fileSize ?? Int64((try? Data(contentsOf: exportedAsset.fileURL).count) ?? 0)

        if size >= AppConfiguration.multipartUploadThresholdBytes {
            return try await uploadResumable(exportedAsset, parentFolderID: parentFolderID, token: token, size: size)
        }

        return try await uploadMultipart(exportedAsset, parentFolderID: parentFolderID, token: token)
    }

    func findFile(name: String, parentFolderID: String, token: String) async throws -> DriveFile? {
        var components = URLComponents(url: baseFilesURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: "mimeType != 'application/vnd.google-apps.folder' and name = '\(name.escapedDriveQuery)' and '\(parentFolderID.escapedDriveQuery)' in parents and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name,size)")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setBearerToken(token)

        let response: DriveFileList = try await send(request)
        return response.files.first
    }

    private func findOrCreateFolder(
        name: String,
        parentID: String,
        path: String,
        token: String,
        stateStore: UploadStateStore
    ) async throws -> String {
        if let cachedID = try await stateStore.cachedFolderID(for: path) {
            AppLogger.debug("Drive folder cache hit for \(path)")
            return cachedID
        }

        if let existing = try await findFolder(name: name, parentID: parentID, token: token) {
            try await stateStore.saveFolderID(existing.id, for: path)
            AppLogger.info("Reusing Drive folder \(path)")
            return existing.id
        }

        let created = try await createFolder(name: name, parentID: parentID, token: token)
        try await stateStore.saveFolderID(created.id, for: path)
        AppLogger.info("Created Drive folder \(path)")
        return created.id
    }

    private func findFolder(name: String, parentID: String, token: String) async throws -> DriveFile? {
        var components = URLComponents(url: baseFilesURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: "mimeType = 'application/vnd.google-apps.folder' and name = '\(name.escapedDriveQuery)' and '\(parentID.escapedDriveQuery)' in parents and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name)")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setBearerToken(token)

        let response: DriveFileList = try await send(request)
        return response.files.first
    }

    private func createFolder(name: String, parentID: String, token: String) async throws -> DriveFile {
        var request = URLRequest(url: baseFilesURL)
        request.httpMethod = "POST"
        request.setBearerToken(token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DriveFileMetadata(
                name: name,
                mimeType: "application/vnd.google-apps.folder",
                parents: [parentID]
            )
        )

        return try await send(request)
    }

    private func uploadMultipart(_ exportedAsset: ExportedPhotoAsset, parentFolderID: String, token: String) async throws -> DriveFile {
        var components = URLComponents(url: uploadFilesURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: "id,name,size")
        ]

        let boundary = "Boundary-\(UUID().uuidString)"
        let metadata = DriveFileMetadata(name: exportedAsset.filename, mimeType: nil, parents: [parentFolderID])
        let metadataData = try JSONEncoder().encode(metadata)
        let fileData = try Data(contentsOf: exportedAsset.fileURL)
        var body = Data()

        body.append("--\(boundary)\r\n")
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metadataData)
        body.append("\r\n--\(boundary)\r\n")
        body.append("Content-Type: \(exportedAsset.mimeType)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setBearerToken(token)
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        AppLogger.info("Starting multipart upload for \(exportedAsset.filename)")
        return try await send(request)
    }

    private func uploadResumable(_ exportedAsset: ExportedPhotoAsset, parentFolderID: String, token: String, size: Int64) async throws -> DriveFile {
        var components = URLComponents(url: uploadFilesURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "resumable"),
            URLQueryItem(name: "fields", value: "id,name,size")
        ]

        let metadata = DriveFileMetadata(name: exportedAsset.filename, mimeType: nil, parents: [parentFolderID])
        var startRequest = URLRequest(url: components.url!)
        startRequest.httpMethod = "POST"
        startRequest.setBearerToken(token)
        startRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        startRequest.setValue(exportedAsset.mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        startRequest.setValue("\(size)", forHTTPHeaderField: "X-Upload-Content-Length")
        startRequest.httpBody = try JSONEncoder().encode(metadata)

        let (_, startResponse) = try await data(for: startRequest)
        guard let httpResponse = startResponse as? HTTPURLResponse else {
            throw GoogleDriveError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode), let uploadURL = httpResponse.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)) else {
            throw GoogleDriveError.httpStatus(
                httpResponse.statusCode,
                "Failed to start resumable upload.",
                retryAfter: httpResponse.retryAfterDelay
            )
        }

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue(exportedAsset.mimeType, forHTTPHeaderField: "Content-Type")
        uploadRequest.setValue("\(size)", forHTTPHeaderField: "Content-Length")
        uploadRequest.httpBody = try Data(contentsOf: exportedAsset.fileURL)

        AppLogger.info("Starting resumable upload for \(exportedAsset.filename)")
        return try await send(uploadRequest)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleDriveError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw GoogleDriveError.httpStatus(httpResponse.statusCode, message, retryAfter: httpResponse.retryAfterDelay)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GoogleDriveError.decodingFailed(error)
        }
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await rateLimiter.waitForTurn()
        return try await session.data(for: request)
    }
}

actor GoogleDriveRateLimiter {
    private let maxRequestsPerSecond: Int
    private var requestDates: [Date] = []
    private let window: TimeInterval = 1

    init(maxRequestsPerSecond: Int) {
        self.maxRequestsPerSecond = max(1, maxRequestsPerSecond)
    }

    func waitForTurn() async throws {
        while true {
            let now = Date()
            requestDates.removeAll { now.timeIntervalSince($0) >= window }

            if requestDates.count < maxRequestsPerSecond {
                requestDates.append(now)
                return
            }

            guard let oldestRequestDate = requestDates.first else {
                continue
            }

            let waitTime = max(0.05, window - now.timeIntervalSince(oldestRequestDate))
            try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        }
    }
}

struct DriveFile: Codable, Sendable {
    let id: String
    let name: String?
    let size: String?
}

private struct DriveFileList: Codable {
    let files: [DriveFile]
}

private struct DriveFileMetadata: Encodable {
    let name: String
    let mimeType: String?
    let parents: [String]
}

enum GoogleDriveError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int, String, retryAfter: TimeInterval?)
    case decodingFailed(Error)

    static func == (lhs: GoogleDriveError, rhs: GoogleDriveError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidResponse, .invalidResponse):
            true
        case let (.httpStatus(lhsCode, _, _), .httpStatus(rhsCode, _, _)):
            lhsCode == rhsCode
        case (.decodingFailed, .decodingFailed):
            true
        default:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Google Drive returned an invalid response."
        case let .httpStatus(statusCode, message, _):
            "Google Drive error \(statusCode): \(message)"
        case let .decodingFailed(error):
            "Failed to decode Google Drive response: \(error.localizedDescription)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case let .httpStatus(statusCode, _, _):
            return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
        case .invalidResponse, .decodingFailed:
            return false
        }
    }

    var retryAfterDelay: TimeInterval? {
        switch self {
        case let .httpStatus(_, _, retryAfter):
            retryAfter
        case .invalidResponse, .decodingFailed:
            nil
        }
    }
}

private extension HTTPURLResponse {
    var retryAfterDelay: TimeInterval? {
        guard let retryAfter = value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }

        if let seconds = TimeInterval(retryAfter) {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"

        guard let date = formatter.date(from: retryAfter) else {
            return nil
        }

        return max(0, date.timeIntervalSinceNow)
    }
}

private extension URLRequest {
    mutating func setBearerToken(_ token: String) {
        setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}

private extension String {
    var escapedDriveQuery: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
