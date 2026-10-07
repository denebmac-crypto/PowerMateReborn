#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="PowerMateReborn"
PRODUCT="PowerMateDriver"
VERSION="1.0.01"
BUNDLE_ID="com.spica.PowerMateReborn"
BUILD_ROOT="$ROOT/.build/universal-app"
ARM_BUILD="$BUILD_ROOT/arm64"
INTEL_BUILD="$BUILD_ROOT/x86_64"
APP="$ROOT/$APP_NAME.app"

rm -rf "$BUILD_ROOT" "$APP"
mkdir -p "$BUILD_ROOT"

echo "==> Building arm64..."
swift build -c release --arch arm64 --scratch-path "$ARM_BUILD"

echo "==> Building x86_64..."
swift build -c release --arch x86_64 --scratch-path "$INTEL_BUILD"

ARM_BIN="$(swift build -c release --arch arm64 --scratch-path "$ARM_BUILD" --show-bin-path)/$PRODUCT"
INTEL_BIN="$(swift build -c release --arch x86_64 --scratch-path "$INTEL_BUILD" --show-bin-path)/$PRODUCT"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

echo "==> Creating Universal Binary..."
lipo -create "$ARM_BIN" "$INTEL_BIN" -output "$APP/Contents/MacOS/$PRODUCT"
chmod +x "$APP/Contents/MacOS/$PRODUCT"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>PowerMateReborn</string>
    <key>CFBundleExecutable</key>
    <string>PowerMateDriver</string>
    <key>CFBundleIdentifier</key>
    <string>com.spica.PowerMateReborn</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PowerMateReborn</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.01</string>
    <key>CFBundleVersion</key>
    <string>1001</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

copy_resources() {
    local BIN_DIR="$1"
    local BUNDLE
    BUNDLE="$(find "$BIN_DIR" -maxdepth 1 -type d -name '*.bundle' -print -quit || true)"
    if [[ -n "$BUNDLE" ]]; then
        echo "==> Copying SwiftPM resource bundle..."
        ditto "$BUNDLE" "$APP/Contents/Resources/$(basename "$BUNDLE")"
    fi
}

copy_resources "$(dirname "$ARM_BIN")"

# If Sparkle.framework was staged by SwiftPM, embed it so the app remains
# self-contained. Sparkle is weak-linked and the updater is currently disabled.
for BIN_DIR in "$(dirname "$ARM_BIN")" "$(dirname "$INTEL_BIN")"; do
    if [[ -d "$BIN_DIR/PackageFrameworks/Sparkle.framework" ]]; then
        if [[ ! -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
            ditto "$BIN_DIR/PackageFrameworks/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
        fi
        break
    fi
done

echo "==> Verifying Universal Binary..."
file "$APP/Contents/MacOS/$PRODUCT"

# Local ad-hoc signature. This is sufficient for local installation/testing.
codesign --force --deep --sign - "$APP"

echo "==> Installing to /Applications..."
rm -rf "/Applications/$APP_NAME.app"
ditto "$APP" "/Applications/$APP_NAME.app"

echo
echo "Installed: /Applications/$APP_NAME.app"
echo
echo "Architecture:"
file "/Applications/$APP_NAME.app/Contents/MacOS/$PRODUCT"
echo
echo "Done."
