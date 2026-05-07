#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_INVOCATION="$0"
EXECUTABLE_NAME="NetPulse"
PRODUCT_NAME="net-pulse"
APP_DISPLAY_NAME="网速监控"
CONFIGURATION="release"
TARGET="dmg"
APP_BUNDLE="$PROJECT_DIR/dist/$PRODUCT_NAME.app"
DMG_PATH="$PROJECT_DIR/dist/$PRODUCT_NAME.dmg"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SOURCE="$PROJECT_DIR/Resources/AppIcon.png"

usage() {
  echo "Usage: $SCRIPT_INVOCATION [app] [--debug]" >&2
  echo "" >&2
  echo "Examples:" >&2
  echo "  $SCRIPT_INVOCATION              Build release DMG at dist/$PRODUCT_NAME.dmg" >&2
  echo "  $SCRIPT_INVOCATION --debug      Build debug DMG at dist/$PRODUCT_NAME.dmg" >&2
  echo "  $SCRIPT_INVOCATION app          Build release app at dist/$PRODUCT_NAME.app" >&2
  echo "  $SCRIPT_INVOCATION app --debug  Build debug app at dist/$PRODUCT_NAME.app" >&2
}

for arg in "$@"; do
  case "$arg" in
    app)
      TARGET="app"
      ;;
    --debug)
      CONFIGURATION="debug"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unsupported argument: $arg" >&2
      usage
      exit 1
      ;;
  esac
done

BIN_PATH="$(swift build --configuration "$CONFIGURATION" --package-path "$PROJECT_DIR" --show-bin-path)"

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Icon source not found: $ICON_SOURCE" >&2
  exit 1
fi

swift build --configuration "$CONFIGURATION" --package-path "$PROJECT_DIR"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH/$PRODUCT_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"
cp "$ICON_SOURCE" "$RESOURCES_DIR/AppIcon.png"
swift "$PROJECT_DIR/scripts/generate_app_icon.swift" "$ICON_SOURCE" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.netpulse.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundleName</key>
    <string>$APP_DISPLAY_NAME</string>
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

if [[ "$TARGET" == "app" ]]; then
  echo "Packaged $CONFIGURATION app:"
  echo "$APP_BUNDLE"
  exit 0
fi

DMG_STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/netpulse-dmg.XXXXXX")"
cleanup() {
  rm -rf "$DMG_STAGING_DIR"
}
trap cleanup EXIT

cp -R "$APP_BUNDLE" "$DMG_STAGING_DIR/$PRODUCT_NAME.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$PRODUCT_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "Packaged $CONFIGURATION DMG:"
echo "$DMG_PATH"
