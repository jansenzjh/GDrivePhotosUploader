import Combine
import SwiftUI

@main
struct GDrivePhotosUploaderApp: App {
    @StateObject private var authService = GoogleAuthService()
    @StateObject private var syncManager: SyncManager

    init() {
        let authService = GoogleAuthService()
        _authService = StateObject(wrappedValue: authService)
        _syncManager = StateObject(
            wrappedValue: SyncManager(
                authService: authService,
                photoLibraryService: PhotoLibraryService(),
                driveService: GoogleDriveService(),
                stateStore: UploadStateStore()
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authService)
                .environmentObject(syncManager)
                .task {
                    await authService.restorePreviousSignIn()
                    await syncManager.refreshPhotoAuthorization()
                }
                .onOpenURL { url in
                    _ = authService.handleOpenURL(url)
                }
        }
    }
}
