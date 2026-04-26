import Combine
import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var authService: GoogleAuthService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Google Drive", systemImage: "person.crop.circle.badge.checkmark")

            if authService.isConfigured {
                LabeledContent("Status") {
                    Text(authService.isSignedIn ? "Signed in" : "Not signed in")
                        .foregroundStyle(authService.isSignedIn ? .green : .secondary)
                }

                if let email = authService.userEmail {
                    LabeledContent("Account", value: email)
                }

                HStack {
                    Button(authService.isSignedIn ? "Refresh Login" : "Sign in with Google") {
                        Task {
                            await authService.signIn()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    if authService.isSignedIn {
                        Button("Logout", role: .destructive) {
                            authService.signOut()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                Text("Google client ID is not configured. Paste your iOS OAuth client ID into AppConfiguration.swift before signing in.")
                    .foregroundStyle(.red)
            }

            if let latestError = authService.latestError {
                Text(latestError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .cardStyle()
    }
}
