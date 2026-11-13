#!/usr/bin/env bash
# ==============================================================================
# Drishti macOS Production Code Signing & Packaging Utility
# Resolves macOS Gatekeeper "App is damaged and can't be opened" errors caused by
# post-build asset injection violating Apple's CodeResources cryptographic seal.
# ==============================================================================
set -euo pipefail

APP_PATH="${1:-/Users/maha/Downloads/Drishti.app}"
OUTPUT_DIR="${2:-$(pwd)/binaries}"
VERSION="${3:-1.7.1}"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: App bundle not found at '$APP_PATH'"
    exit 1
fi

echo "=================================================="
echo " Drishti macOS Code Signing & Packaging Suite"
echo " Target Bundle: $APP_PATH"
echo " Release Version: $VERSION"
echo "=================================================="

# 1. Strip macOS extended attributes and quarantine flags
echo "🧹 1/6: Stripping extended attributes & quarantine flags..."
xattr -cr "$APP_PATH"
find "$APP_PATH" -name ".DS_Store" -delete 2>/dev/null || true

# 2. Normalize POSIX permissions
echo "🔒 2/6: Normalizing bundle file permissions..."
chmod -R u=rwX,go=rX "$APP_PATH"
if [ -f "$APP_PATH/Contents/MacOS/Drishti" ]; then
    chmod +x "$APP_PATH/Contents/MacOS/Drishti"
elif [ -f "$APP_PATH/Contents/MacOS/netra_ai_mobile" ]; then
    mv "$APP_PATH/Contents/MacOS/netra_ai_mobile" "$APP_PATH/Contents/MacOS/Drishti"
    chmod +x "$APP_PATH/Contents/MacOS/Drishti"
fi

# 3. Update Info.plist bundle metadata
echo "📝 3/6: Updating Info.plist bundle metadata..."
python3 - <<EOF
import plistlib, os
plist_file = os.path.join("$APP_PATH", "Contents", "Info.plist")
if os.path.exists(plist_file):
    with open(plist_file, "rb") as f:
        pl = plistlib.load(f)
    pl["CFBundleDisplayName"] = "Drishti"
    pl["CFBundleName"] = "Drishti"
    pl["CFBundleShortVersionString"] = "$VERSION"
    pl["CFBundleVersion"] = "$VERSION"
    with open(plist_file, "wb") as f:
        plistlib.dump(pl, f)
    print("   ✓ CFBundleDisplayName: Drishti")
    print("   ✓ CFBundleName: Drishti")
    print(f"   ✓ Version: $VERSION")
EOF

# 4. Canonical inside-out code signing
echo "✍️ 4/6: Executing inside-out cryptographic code signing..."
# Sign nested dylibs
find "$APP_PATH" -name "*.dylib" | while read -r dylib; do
    codesign --force --sign - --timestamp=none "$dylib"
done

# Sign nested bundles
find "$APP_PATH" -name "*.bundle" | while read -r bundle; do
    codesign --force --sign - --timestamp=none "$bundle"
done

# Sign nested frameworks
if [ -d "$APP_PATH/Contents/Frameworks" ]; then
    find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -name "*.framework" | while read -r framework; do
        codesign --force --sign - --timestamp=none "$framework"
    done
fi

# Sign main executable
if [ -f "$APP_PATH/Contents/MacOS/Drishti" ]; then
    codesign --force --sign - --timestamp=none "$APP_PATH/Contents/MacOS/Drishti"
elif [ -f "$APP_PATH/Contents/MacOS/netra_ai_mobile" ]; then
    codesign --force --sign - --timestamp=none "$APP_PATH/Contents/MacOS/netra_ai_mobile"
fi

# Sign outer app bundle
codesign --force --sign - --timestamp=none "$APP_PATH"

# 5. Strict verification
echo "🔍 5/6: Verifying sealed bundle integrity..."
codesign --verify --deep --strict --verbose=4 "$APP_PATH"
echo "   ✓ Bundle satisfies Designated Requirement and is cryptographically intact on disk."

# 6. Package into distribution ZIP preserving symlinks
echo "📦 6/6: Packaging standalone zip archives..."
mkdir -p "$OUTPUT_DIR"
PARENT_DIR="$(dirname "$APP_PATH")"
APP_NAME="$(basename "$APP_PATH")"

(
    cd "$PARENT_DIR"
    zip -r -y -q "$OUTPUT_DIR/drishti_macos_v${VERSION}.zip" "$APP_NAME"
    zip -r -y -q "$OUTPUT_DIR/drishti_macos_v1.7.0.zip" "$APP_NAME"
)

echo "=================================================="
echo "✅ SUCCESS: macOS release packages created:"
echo "   - $OUTPUT_DIR/drishti_macos_v${VERSION}.zip"
echo "   - $OUTPUT_DIR/drishti_macos_v1.7.0.zip"
echo "=================================================="
