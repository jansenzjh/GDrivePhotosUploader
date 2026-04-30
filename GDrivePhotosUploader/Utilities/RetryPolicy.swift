import Foundation

struct RetryPolicy: Sendable {
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval

    static let upload = RetryPolicy(maxAttempts: 4, baseDelay: 1, maxDelay: 20)

    func run<T>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        var attempt = 1
        var lastError: Error?

        while attempt <= maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt == maxAttempts || !Self.isRetryable(error) {
                    throw error
                }

                let backoffDelay = min(maxDelay, baseDelay * pow(2, Double(attempt - 1)))
                let retryAfterDelay = (error as? GoogleDriveError)?.retryAfterDelay
                let jitter = TimeInterval.random(in: 0...1)
                let delay = min(maxDelay, max(backoffDelay, retryAfterDelay ?? 0) + jitter)
                AppLogger.info("Retry attempt \(attempt + 1) in \(String(format: "%.1f", delay))s after error: \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            }
        }

        throw lastError ?? CancellationError()
    }

    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed, .internationalRoamingOff, .callIsActive, .dataNotAllowed:
                return true
            default:
                return false
            }
        }

        if let driveError = error as? GoogleDriveError {
            return driveError.isRetryable
        }

        return false
    }
}
