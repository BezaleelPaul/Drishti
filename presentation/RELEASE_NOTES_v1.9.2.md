# Drishti v1.9.2 — Cross-Platform Clinical Parity

### Release Highlights

**Drishti v1.9.2** takes the macOS reliability work from v1.9.1 and makes it the **default behaviour on every operating system**. Windows, Linux, Android and iOS now use the same resilient file-picking, persistent patient history, PDF export and native report-opening paths as macOS — with one shared code path instead of per-platform shortcuts.

---

#### 1. One Persistence Layer on Every OS
- **Desktop database engine:** `LocalStore` now selects SQLCipher on Android/iOS/macOS and a native SQLite FFI engine on Windows/Linux. The encrypted patient vault, screening schema and migrations are identical everywhere, so history is no longer limited to the JSON tiers on desktop.
- **Persistent fundus images:** Captured images are written to the application-support container instead of the OS temp directory. Reports and history retain their retinal photographs after an app restart, OS temp cleanup, or device reboot.
- **Queue durability:** The offline store-and-forward queue resolves its database path per platform and survives process kills on desktop as well as mobile.
- **Resilient first edit:** Editing a patient record now creates the filesystem backup on first use instead of silently skipping it when the backup file does not exist.

#### 2. Universal File Picking
- The macOS-only `FilePicker.skipEntitlementsChecks()` pre-flight is now encapsulated in one cross-platform service. It remains a no-op outside macOS.
- Fundus photos are read **path-first, fallback-to-platform-read**: desktop paths, macOS security-scoped URLs and Android/iOS content providers all resolve to bytes without an empty-file failure.
- Cancelling the picker is distinguished from an unreadable file so the operator sees the correct message on every OS.

#### 3. Report Export That Behaves Everywhere
- PDFs are saved to `~/Downloads` on desktop when writable, with automatic fallback to the documents/application-support containers. Android/iOS save into the app documents container and expose it through the iOS Files app.
- The **Open Report** action now uses the native handler on every platform (`open` on macOS, `xdg-open` on Linux, `ShellExecute` on Windows, document viewer on Android/iOS) instead of a macOS-only `Process.run` call.
- Filenames are sanitised for Windows, macOS and Linux filesystems.

#### 4. Live Desktop Camera Parity
- Desktop capture now supports **Linux V4L2**, **macOS AVFoundation** and **Windows DirectShow** through `ffmpeg`, with automatic device discovery and a clear permission/device error.
- A 10-second startup watchdog replaces the endless spinner when a camera is busy, denied or unavailable.
- Upload Photo remains the fallback on every platform.

#### 5. Correct Platform Permissions
- **macOS:** added `com.apple.security.device.camera`, `com.apple.security.files.downloads.read-write`, and `NSCameraUsageDescription`; the signing script now ships a matching entitlement set and a one-click `run_macos.command`.
- **iOS:** added photo-library usage descriptions, `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` so clinical reports are visible in Files.
- **Android:** the native report opener's broad media permissions are explicitly removed; only `INTERNET` and `CAMERA` remain.

#### 6. Release Engineering & UI Continuity
- Added a CI **quality gate** that runs static analysis plus persistence, queue, PDF, quality-gate and de-identification tests before any binary is built.
- All five platform builds run in parallel after the gate; release assets are versioned (`Drishti_mobile_v1.9.2.apk`, `Drishti_linux_v1.9.2.tar.gz`, `Drishti_windows_v1.9.2.zip`, `Drishti_macos_v1.9.2.zip`, `Drishti_ios_unsigned_v1.9.2.zip`).
- Linux, Windows and macOS archives now include one-click launch scripts.
- Existing Drishti HUD styling, dark clinical theme, typography and layouts are preserved; only platform feedback text and success actions were made consistent.

---

### Downloads

| Platform | Asset | How to run |
| :--- | :--- | :--- |
| **Android** | `Drishti_mobile_v1.9.2.apk` | Sideload; signed release build with the on-device model |
| **Linux x86_64** | `Drishti_linux_v1.9.2.tar.gz` | Extract and run `./run_drishti.sh` |
| **Windows x86_64** | `Drishti_windows_v1.9.2.zip` | Extract and run `run_drishti.bat` or `drishti.exe` |
| **macOS** | `Drishti_macos_v1.9.2.zip` | Extract and double-click `run_macos.command` |
| **iOS** | `Drishti_ios_unsigned_v1.9.2.zip` | Unsigned bundle for sideloading / TestFlight signing |

### Upgrade Notes
- Existing Android/iOS/macOS patient vaults keep their original database location; no migration is required.
- Windows/Linux now gain a persistent SQLite history database. Existing JSON-backed records are merged automatically by the existing multi-tier history loader.
- The macOS bundle remains ad-hoc signed; use `run_macos.command` on first launch to clear the quarantine flag.
