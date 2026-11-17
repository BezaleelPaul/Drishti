# Drishti Android Release Signing

**The release keystore is no longer stored in this repository.** A committed
keystore with a published password lets anyone sign a malicious APK that the
device/update system treats as Drishti. The keys are rotated for v1.10.0 and
must be handled as production secrets.

## CI configuration (GitHub Actions)

The release workflow (`build-all-platforms.yml`) restores the keystore from
repository secrets at build time:

| Secret | Contents |
| :--- | :--- |
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 drishti-release.jks` |
| `ANDROID_STORE_PASSWORD` | Strong store password |
| `ANDROID_KEY_ALIAS` | `drishti` |
| `ANDROID_KEY_PASSWORD` | Strong key password |

No secret is written to the repository or logs. Fork pull requests cannot read
repository secrets, so the signed Android job is skipped for fork PRs.

## Local release build

```bash
keytool -genkeypair -v -keystore drishti-release.jks -alias drishti \
  -keyalg RSA -keysize 4096 -validity 10000
cp flutter_app/android/key.properties.template flutter_app/android/key.properties
# edit storeFile/storePassword/keyPassword in key.properties
```

`key.properties` and every `*.jks` / `*.keystore` are gitignored.

## Rotation notice

v1.10.0 is signed with a new key (SHA-256 fingerprint
`10:38:A8:5A:9A:74:B5:2A:9F:5E:1E:6E:8F:93:39:7B:DA:AC:EA:58:1D:7C:CB:5E:CF:5F:83:D0:D2:EB:A3:C1`).
Android will reject an in-place update from the v1.9.x key; users must
uninstall the old sideloaded build once before installing v1.10.0.
