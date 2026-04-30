import Foundation
import OSLog

enum AppLogger {
    private static let logger = Logger(subsystem: "com.example.GDrivePhotosUploader", category: "App")
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static var logFileURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GDrivePhotosUploader", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("app.log")
    }

    static var reviewLogFileURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GDrivePhotosUploader", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("warnings-errors.log")
    }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append(level: "INFO", message: message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append(level: "ERROR", message: message)
    }

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        append(level: "DEBUG", message: message)
    }

    static func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        append(level: "WARN", message: message)
    }

    static func readLog() -> String {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: reviewLogFileURL), let text = String(data: data, encoding: .utf8) else {
            return "No warnings or errors yet."
        }

        return text.isEmpty ? "No warnings or errors yet." : text
    }

    static func clearLog() {
        lock.lock()
        defer { lock.unlock() }

        try? Data().write(to: logFileURL, options: [.atomic])
        try? Data().write(to: reviewLogFileURL, options: [.atomic])
    }

    private static func append(level: String, message: String) {
        lock.lock()
        defer { lock.unlock() }

        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        append(data, to: logFileURL)

        if level == "WARN" || level == "ERROR" {
            append(data, to: reviewLogFileURL)
        }
    }

    private static func append(_ data: Data, to url: URL) {
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: [.atomic])
        }
    }
}
