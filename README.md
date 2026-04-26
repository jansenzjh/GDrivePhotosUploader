# GDrive Photos Uploader

## Background

This app came from my own workflow. I liked how OneDrive uploads iPhone photos as traditional files in normal folders, even though I moved my storage workflow to Google Drive. Google’s default path pushes photo backup through Google Photos, but I wanted regular files directly in Drive with a folder structure I control.

I also did not want to sign in to my Google account from a random App Store app that offers a similar feature. So I made my own Google Drive photo uploader with the structure I prefer with help from Codex and use it every time after traveling.

Important: this app does not remove, replace, or manage anything in Google Photos. If you use both Google Photos backup and this app, the same image/video can exist twice in Google’s ecosystem: once in Google Photos and once as a traditional file in Google Drive.

This is a personal iPhone app for manually uploading Photos Library images and videos to Google Drive. This version is a manual catch-up sync: open the app, sign in, grant Photos access, choose the earliest creation date to sync from, tap Sync, and keep the app open while it uploads missing assets.

The app also includes a Settings tab with an app log viewer for troubleshooting sync, upload, and duplicate-detection behavior.

Uploaded files are organized in Google Drive as:

```text
/iPhone Photos/YYYY/MM/
```

The local Photos asset `localIdentifier` is used as the duplicate-prevention key. Successful uploads are stored in a JSON state file under the app's Application Support directory.

Uploaded filenames use the Photos creation timestamp and original extension:

```text
YYYYMMDD_hhmmsszzz_iOS.ext
```

Example:

```text
20250101_041530330_iOS.jpg
```

## Requirements

- Xcode with iOS 17+ SDK.
- A physical iPhone is recommended because the simulator Photos Library is limited.
- Google Cloud project with Google Drive API enabled.
- iOS OAuth client configured with this app's bundle ID.

## Google Cloud Setup

1. Open Google Cloud Console.
2. Create or select a project.
3. Enable **Google Drive API**.
4. Configure the OAuth consent screen. For personal use, keep the app in **Testing** mode unless you plan to publish it.
5. Add your personal Google account under **OAuth consent screen** -> **Audience** -> **Test users**. If you do not add the account you use on the iPhone, Google Sign-In may fail or block access while the app is in Testing mode.
6. Create credentials: **OAuth client ID** -> **iOS**.
7. Use bundle ID:

```text
com.example.GDrivePhotosUploader
```

8. Copy the generated **iOS client ID**.
9. Copy the generated **iOS URL scheme**, usually the reversed client ID.

## App Configuration

Before running, create your local ignored config file:

```bash
cp Config/LocalConfig.template.xcconfig Config/LocalConfig.xcconfig
```

Then edit `Config/LocalConfig.xcconfig`:

```text
GOOGLE_IOS_CLIENT_ID = your-ios-client-id.apps.googleusercontent.com
GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.your-reversed-client-id
```

The app reads `GIDClientID` from the processed `Info.plist`, and `Info.plist` gets that value from `LocalConfig.xcconfig`. You should not need to edit Swift source files for local credentials.

The project references committed `Config/BaseConfig.xcconfig`, which contains safe placeholders and optionally includes ignored `Config/LocalConfig.xcconfig`. Your local Google values override the placeholders without touching tracked files.

Do not commit real credentials if you later publish this repository. The OAuth client ID is not a secret, but keeping personal configuration out of public repos is still cleaner.

## Running

1. Open `GDrivePhotosUploader.xcodeproj` in Xcode.
2. Let Xcode resolve the Swift Package dependency for `GoogleSignIn`.
3. Select the `GDrivePhotosUploader` scheme.
4. Select a connected iPhone running iOS 17 or later.
5. Build and run.
6. Sign in with Google.
7. Grant Photos access.
8. Pick the **Sync photos after** date.
9. Tap **Sync**.

During the initial Photos scan, the app shows a loading overlay while the scan runs off the main UI actor. Large libraries can still take time, but the screen should not appear frozen.

## Testing With a Small Photo Set

Use limited Photos access first:

1. When iOS asks for Photos permission, choose limited access.
2. Select a small number of photos/videos.
3. Pick a recent **Sync photos after** date.
4. Tap Sync.
5. Confirm Google Drive contains `/iPhone Photos/YYYY/MM/`.
6. Run Sync again and confirm the already-uploaded files are skipped.

## Behavior and Limitations

- The app requests the Drive scope `https://www.googleapis.com/auth/drive.file`.
- `drive.file` is intentionally narrow. The app can manage files it creates or files opened/authorized through the app, not the entire Drive.
- Large files use a resumable upload session, but v1 uploads the file in one PUT request after creating the session. The code is structured so chunked/background resumable upload can be improved later.
- Sync is manual and foreground-first. iOS can suspend or kill apps in the background, so v1 does not claim perfect background auto-sync.
- If the app is killed mid-upload, incomplete files are not marked uploaded locally. The next manual sync retries missing assets.
- Duplicate filenames are allowed by Google Drive. Local duplicate prevention is based on Photos asset identifiers, not filenames.
- Before uploading, the app checks whether the generated filename already exists in the target Drive month folder. If it exists, the app logs a warning, records that asset locally, and skips the upload to reduce duplicate uploads after reinstall.

## Logs

The app writes logs to a local file in Application Support and mirrors important messages to Apple's unified logging system.

Open **Settings** -> **View App Log** to:

- Review sync, Photos permission, folder creation/reuse, upload, retry, and duplicate warning events.
- Copy the full log to the clipboard for deeper investigation.
- Clear the log after confirmation when it is no longer needed.

Clearing logs does not delete upload records or any files in Google Drive.

## Future Improvements

- Chunked resumable uploads with persisted upload session URLs.
- Background `URLSession` for better long-running video uploads.
- SQLite/CoreData-backed state store.
- Better retry queue and resumable recovery after app termination.
- Richer limited-library management UI.
- Optional checksum or Drive-side duplicate detection.
