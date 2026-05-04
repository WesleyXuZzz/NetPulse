#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="NetPulse"
CONFIGURATION="${1:-release}"
APP_BUNDLE="$PROJECT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SOURCE="$PROJECT_DIR/Resources/AppIcon.png"

case "$CONFIGURATION" in
  debug|release) ;;
  *)
    echo "Unsupported configuration: $CONFIGURATION" >&2
    echo "Usage: $0 [debug|release]" >&2
    exit 1
    ;;
esac

BIN_PATH="$(swift build --configuration "$CONFIGURATION" --package-path "$PROJECT_DIR" --show-bin-path)"

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Icon source not found: $ICON_SOURCE" >&2
  exit 1
fi

swift build --configuration "$CONFIGURATION" --package-path "$PROJECT_DIR"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
cp "$ICON_SOURCE" "$RESOURCES_DIR/AppIcon.png"
swift "$PROJECT_DIR/scripts/generate_app_icon.swift" "$ICON_SOURCE" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>NetPulse</string>
    <key>CFBundleIdentifier</key>
    <string>com.netpulse.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>NetPulse</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

touch "$CONTENTS_DIR/PkgInfo"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null

echo "Packaged $CONFIGURATION app:"
echo "$APP_BUNDLE"
