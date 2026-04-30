# AGENTS.md

Notes for future agents working in this repository. Read this first so you do not need to rediscover the whole app from scratch.

## What This App Is

`GDrivePhotosUploader` is a personal SwiftUI iPhone app for manually uploading Photos Library images and videos to Google Drive as normal files. It exists because the owner wants OneDrive-style file/folder photo backup while using Google Drive, without signing into a third-party App Store app.

The app does not manage Google Photos. If the user also has Google Photos backup enabled, an asset can exist both in Google Photos and in Google Drive.

Primary workflow:

1. Open app on a physical iPhone.
2. Sign in with Google.
3. Grant Photos permission, including limited-library access if desired.
4. Pick the earliest creation date in **Sync photos after**.
5. Tap **Sync** and keep the app in the foreground.

Uploaded Drive path:

```text
/iPhone Photos/YYYY/MM/
```

Uploaded filename format:

```text
YYYYMMDD_HHmmssSSS_iOS.ext
```

Example:

```text
20250101_041530330_iOS.jpg
```

## Project Shape

- iOS app target: `GDrivePhotosUploader`
- UI framework: SwiftUI
- Deployment target: iOS 17.0
- Package dependency: `GoogleSignIn` from `https://github.com/google/GoogleSignIn-iOS`
- Main scheme: `GDrivePhotosUploader`
- Xcode project: `GDrivePhotosUploader.xcodeproj`
- App bundle ID currently in the project: `com.JZSoft.GDrivePhotosUploader`

Important directories:

- `GDrivePhotosUploader/App`: app entry point and dependency wiring.
- `GDrivePhotosUploader/Views`: SwiftUI screens.
- `GDrivePhotosUploader/Services`: Google auth, Photos, Drive upload, sync coordination, local state.
- `GDrivePhotosUploader/Models`: small Codable/Sendable model structs.
- `GDrivePhotosUploader/Utilities`: config, logging, retry policy.
- `Config`: Info.plist and xcconfig files.

## Configuration

Local credentials belong in ignored `Config/LocalConfig.xcconfig`, copied from `Config/LocalConfig.template.xcconfig`.

Required keys:

```text
GOOGLE_IOS_CLIENT_ID = your-ios-client-id.apps.googleusercontent.com
GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.your-reversed-client-id
```

`Config/BaseConfig.xcconfig` contains placeholder values and includes `LocalConfig.xcconfig` if present. `Config/Info.plist` reads those values into `GIDClientID` and the URL scheme.

Do not hard-code Google credentials in Swift source. The OAuth client ID is not a password, but keep local user config out of tracked files.

## Runtime Architecture

`GDrivePhotosUploaderApp` constructs shared services and injects them as environment objects:

- `GoogleAuthService`
- `SyncManager`

`SyncManager` is `@MainActor` and owns the sync state machine:

- `idle`
- `scanning`
- `syncing`
- `paused`
- `cancelling`
- `completed`
- `failed(String)`

The sync flow is:

1. Confirm Google sign-in and Photos authorization.
2. Refresh a valid Google access token.
3. Scan Photos Library through `PhotoLibraryService`.
4. Filter assets by `syncStartDate.startOfDay`.
5. Load uploaded Photos `localIdentifier`s from `UploadStateStore`.
6. Export pending original assets to a temporary file.
7. Create/reuse Drive folder path `/iPhone Photos/YYYY/MM`.
8. Check for an existing Drive file with the generated filename in that month folder.
9. Upload missing files.
10. Save an `UploadRecord` locally only after successful upload or duplicate filename skip.

## Important Services

`GoogleAuthService`

- Uses Google Sign-In.
- Requests `AppConfiguration.driveScope`, currently `https://www.googleapis.com/auth/drive.file`.
- Restores previous sign-in on launch.
- Refreshes tokens with `refreshTokensIfNeeded` before sync.

`PhotoLibraryService`

- Requests `.readWrite` Photos authorization.
- Supports `.authorized` and `.limited`.
- Scans images and videos sorted by creation date.
- Runs the Photos scan in a detached user-initiated task so the SwiftUI screen does not freeze.
- Exports originals using `PHAssetResourceManager.writeData` with iCloud network access allowed.
- Writes exports to temporary `GDrivePhotosUploaderExports` and `SyncManager` deletes each temp file after upload attempt.

`GoogleDriveService`

- Uses Drive v3 REST APIs directly with `URLSession`.
- Caches Drive folder IDs via `UploadStateStore`.
- Uses multipart upload below `AppConfiguration.multipartUploadThresholdBytes` (`8 MB`).
- Uses resumable upload for larger files, but currently sends the file in a single PUT after creating the session.
- Escapes Drive query strings for folder/file lookup.

`UploadStateStore`

- Actor-backed JSON store.
- File location: app Application Support directory under `GDrivePhotosUploader/upload-state.json`.
- Stores uploaded asset records keyed by Photos `localIdentifier`.
- Stores Drive folder cache entries keyed by path.

`AppLogger`

- Writes to Apple unified logging and a local file.
- Log file location: app Application Support directory under `GDrivePhotosUploader/app.log`.
- Settings tab has a log viewer with refresh, copy, and clear.
- Clearing logs does not delete upload records.

`RetryPolicy`

- Upload retry policy is 4 attempts, exponential delay from 1s up to 20s.
- Retries selected `URLError`s and Drive HTTP 408, 429, and 5xx errors.
- Does not retry cancellation.

## UI Notes

Main UI has two tabs:

- **Sync**: `LoginView` and `SyncView` inside a scroll view.
- **Settings**: `SettingsView`, currently focused on logs and duplicate-skip explanation.

Reusable UI:

- `SectionHeader`
- `View.cardStyle()`

Current `LoginView` unconfigured message still says to paste the client ID into `AppConfiguration.swift`; the README and code now prefer `Config/LocalConfig.xcconfig`. If touching login copy, fix that stale text.

## Duplicate Prevention

The main duplicate key is the Photos asset `localIdentifier`, persisted locally after upload.

There is also Drive-side filename lookup before upload:

- If a generated filename already exists in the target month folder, the app logs a warning.
- It records the asset as uploaded using the existing Drive file ID.
- It skips upload to reduce duplicate files after reinstall or lost local state.

Google Drive allows duplicate filenames, so do not rely on filename uniqueness outside this explicit check.

## Testing and Verification

Useful build command:

```bash
xcodebuild -scheme GDrivePhotosUploader -project GDrivePhotosUploader.xcodeproj -destination 'generic/platform=iOS' build
```

The generated XCTest files are mostly placeholders. There is not much automated coverage yet.

For real behavior, a physical iPhone is recommended because the simulator Photos Library is limited. Manual smoke test:

1. Use limited Photos access with a small set.
2. Pick a recent sync date.
3. Run sync.
4. Confirm Drive has `/iPhone Photos/YYYY/MM/`.
5. Run sync again and confirm already-uploaded assets are skipped.
6. Check Settings -> View App Log for folder creation/reuse, upload, retry, duplicate, and error messages.

## Safe Change Guidelines

- Preserve the app's manual, foreground-first nature unless the user explicitly asks for background sync.
- Be careful around Photos local identifiers; they are the local idempotency key.
- Do not mark an upload as complete until the Drive upload succeeds or Drive filename duplicate skip is intentionally handled.
- Keep Google OAuth configuration in xcconfig/Info.plist, not source.
- Avoid broad Drive scopes unless the user explicitly wants wider Drive access. The current scope is intentionally narrow: `drive.file`.
- For large-upload work, prefer improving the existing resumable-upload path before introducing a new upload subsystem.
- For state-store work, remember current state is JSON in Application Support. SQLite/CoreData is listed as a future improvement, not current behavior.
- This is a personal utility app, so favor reliability, clear logs, and simple UI over generalized product features.
