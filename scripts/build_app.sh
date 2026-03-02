#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="VideoDatasetBrowser"
PRODUCT_BIN="$ROOT_DIR/.build/release/$APP_NAME"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"
BUNDLE_ID="com.samuelschwienbacher.videodatasetbrowser"

usage() {
  cat <<USAGE
Usage:
  scripts/build_app.sh [--install]

Options:
  --install    Copy the built .app bundle to /Applications
USAGE
}

INSTALL=false

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--install" ]]; then
  INSTALL=true
fi

pushd "$ROOT_DIR" >/dev/null
swift build -c release
popd >/dev/null

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$PRODUCT_BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

if [[ "$INSTALL" == true ]]; then
  rm -rf "$INSTALL_PATH"
  cp -R "$APP_BUNDLE" "$INSTALL_PATH"
  echo "Installed: $INSTALL_PATH"
else
  echo "Built: $APP_BUNDLE"
fi
