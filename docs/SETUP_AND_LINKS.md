# ELYTRIVA — Links, Setup & How to Connect

One page with every link and start command. If it isn't here, ask before
improvising.

## 1. Live links

| What | Link |
|---|---|
| Backend API (Render, free tier) | https://drishti-ai-xg6w.onrender.com |
| Backend health check | https://drishti-ai-xg6w.onrender.com/ (expect `"status": "up"`) |
| Release downloads (APK, Windows, macOS, Linux) | https://github.com/BezaleelPaul/ELYTRIVA/releases/tag/v1.0.0-hardened |
| Web demo (auto-deployed from `master`) | https://bezaleelpaul.github.io/ELYTRIVA/ |
| Render dashboard (redeploy, logs, env vars) | https://dashboard.render.com |
| Privacy & access matrix | `docs/PRIVACY.md` |

> Render free tier sleeps when idle: first request can take ~30 s. Open the
> health-check URL a minute before any demo.

## 2. Start the backend
- **Cloud (normal):** nothing to start — Render runs `uvicorn api.main:app`
  on every push to `master`. Check Logs tab if `/` doesn't answer.
- **Local:** `run_windows.bat` (Windows) / `run_mac.sh` (Mac).
  Localhost builds of the apps point at `http://localhost:8000` only when
  built without `--dart-define=DRISHTI_BASE_URL=...`.

## 3. Connect an app build to the backend

Release builds bake these at compile time (see `flutter_app/lib/services/api_service.dart`):

```
--dart-define=DRISHTI_BASE_URL=https://drishti-ai-xg6w.onrender.com
--dart-define=DRISHTI_API_KEY=<operator key from README of secrets>
```

All store builds (APK, Windows, macOS, Linux, web) already carry these.
The app's Online badge goes green when `/status` answers with the key.

## 4. Install per platform

| Platform | File (in `release/archives/`) | How |
|---|---|---|
| Android | `netra_ai_mobile-release.apk` | Uninstall any old debug build first (signature changed), tap APK, allow unknown apps |
| Windows | `netra_ai_windows_app.zip` | Extract, run `netra_ai_mobile.exe`, no install |
| macOS | `ELYTRIVA-macOS-v1.0.0.zip` (CI name: `netra_ai_macos.zip`) | Unzip, right-click `netra_ai_mobile.app` → Open (unsigned bypass, once) |
| Linux | `netra_ai_linux.tar.gz` | `tar -xzf netra_ai_linux.tar.gz && ./bundle/netra_ai_mobile` |
| iOS | — (unsigned CI build only) | Needs Apple Developer account ($99/yr); see CI artifacts |

## 5. Keys & secrets (never commit)

- `DRISHTI_API_KEYS` (Render env) and repo secret of the same name hold
  `operator,doctor,admin` keys. Release builds embed the **operator** key.
- Android `key.properties` + `netra-release.jks` live only on the release
  machine and in CI secrets — losing the keystore ends Play update continuity.
- Rotate any key that ever appears in chat/logs: regenerate, update Render +
  repo secret, rebuild.

## 6. Rebuild everything (release checklist)

```powershell
# Android + Windows (needs Android SDK + VS Build Tools)
cd flutter_app
flutter build apk --release --dart-define=DRISHTI_BASE_URL=<url> --dart-define=DRISHTI_API_KEY=<op-key>
flutter build windows --release --dart-define=DRISHTI_BASE_URL=<url> --dart-define=DRISHTI_API_KEY=<op-key>
# macOS + Linux + iOS (cloud Mac / Linux runners, free)
gh workflow run 'ELYTRIVA CI Pipeline' --ref master
# Publish
gh release upload v1.0.0-hardened <files> --clobber
```
