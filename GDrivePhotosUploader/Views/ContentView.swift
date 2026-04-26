import Combine
import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {
                        LoginView()
                        SyncView()
                    }
                    .padding()
                }
                .navigationTitle("Drive Photo Uploader")
            }
            .tabItem {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}

#Preview {
    let authService = GoogleAuthService()
    return ContentView()
        .environmentObject(authService)
        .environmentObject(
            SyncManager(
                authService: authService,
                photoLibraryService: PhotoLibraryService(),
                driveService: GoogleDriveService(),
                stateStore: UploadStateStore()
            )
        )
}
