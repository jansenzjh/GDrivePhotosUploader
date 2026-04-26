import Combine
import Foundation
import GoogleSignIn
import UIKit

@MainActor
final class GoogleAuthService: ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published private(set) var userEmail: String?
    @Published private(set) var latestError: String?

    init() {
        if AppConfiguration.isGoogleClientIDConfigured {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: AppConfiguration.googleClientID)
        }
    }

    var accessToken: String? {
        GIDSignIn.sharedInstance.currentUser?.accessToken.tokenString
    }

    var isConfigured: Bool {
        AppConfiguration.isGoogleClientIDConfigured
    }

    func restorePreviousSignIn() async {
        guard isConfigured else {
            latestError = "Google client ID is not configured."
            AppLogger.error("Google Sign-In skipped: client ID is not configured")
            return
        }

        do {
            let user = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GIDGoogleUser, Error>) in
                GIDSignIn.sharedInstance.restorePreviousSignIn { user, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let user {
                        continuation.resume(returning: user)
                    } else {
                        continuation.resume(throwing: GoogleAuthError.noRestoredUser)
                    }
                }
            }

            updateSignedInUser(user)
            AppLogger.info("Google previous sign-in restored for \(user.profile?.email ?? "unknown email")")
        } catch {
            isSignedIn = false
            userEmail = nil
            AppLogger.info("No previous Google sign-in restored: \(error.localizedDescription)")
        }
    }

    func signIn() async {
        latestError = nil

        guard isConfigured else {
            latestError = "Paste your Google iOS client ID into AppConfiguration.swift first."
            return
        }

        guard let presentingViewController = UIApplication.shared.firstKeyWindow?.rootViewController?.topMostViewController else {
            latestError = "Unable to find a presenting view controller for Google Sign-In."
            return
        }

        do {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GIDSignInResult, Error>) in
                GIDSignIn.sharedInstance.signIn(
                    withPresenting: presentingViewController,
                    hint: nil,
                    additionalScopes: [AppConfiguration.driveScope]
                ) { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let result {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(throwing: GoogleAuthError.emptySignInResult)
                    }
                }
            }

            updateSignedInUser(result.user)
            AppLogger.info("Google login succeeded for \(result.user.profile?.email ?? "unknown email")")
        } catch {
            latestError = error.localizedDescription
            AppLogger.error("Google login failed: \(error.localizedDescription)")
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        isSignedIn = false
        userEmail = nil
        latestError = nil
        AppLogger.info("Google sign-out completed")
    }

    func handleOpenURL(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    func requireAccessToken() throws -> String {
        guard let token = accessToken else {
            throw GoogleAuthError.missingAccessToken
        }
        return token
    }

    func validAccessToken() async throws -> String {
        guard let currentUser = GIDSignIn.sharedInstance.currentUser else {
            throw GoogleAuthError.missingAccessToken
        }

        let refreshedUser = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GIDGoogleUser, Error>) in
            currentUser.refreshTokensIfNeeded { user, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let user {
                    continuation.resume(returning: user)
                } else {
                    continuation.resume(throwing: GoogleAuthError.missingAccessToken)
                }
            }
        }

        updateSignedInUser(refreshedUser)
        return refreshedUser.accessToken.tokenString
    }

    private func updateSignedInUser(_ user: GIDGoogleUser) {
        isSignedIn = true
        userEmail = user.profile?.email
        latestError = nil
    }
}

enum GoogleAuthError: LocalizedError {
    case noRestoredUser
    case emptySignInResult
    case missingAccessToken

    var errorDescription: String? {
        switch self {
        case .noRestoredUser:
            "No saved Google account was found."
        case .emptySignInResult:
            "Google Sign-In returned no user."
        case .missingAccessToken:
            "Google login expired. Sign in again."
        }
    }
}

private extension UIApplication {
    var firstKeyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

private extension UIViewController {
    var topMostViewController: UIViewController {
        if let presentedViewController {
            return presentedViewController.topMostViewController
        }

        if let navigationController = self as? UINavigationController {
            return navigationController.visibleViewController?.topMostViewController ?? navigationController
        }

        if let tabBarController = self as? UITabBarController {
            return tabBarController.selectedViewController?.topMostViewController ?? tabBarController
        }

        return self
    }
}
