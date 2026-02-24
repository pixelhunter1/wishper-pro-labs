#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Wishper Pro Dev.app"
APP_PATH="/tmp/$APP_NAME"
BUNDLE_ID="com.wishper.pro.dev"
EXECUTABLE_NAME="WishperPro"
ICON_PATH="$ROOT_DIR/Assets/AppIcon.icns"
ENTITLEMENTS_PATH="$ROOT_DIR/Resources/WishperPro.entitlements"

detect_signing_identity() {
  if [[ -n "${WISHPER_SIGN_IDENTITY:-}" ]]; then
    echo "$WISHPER_SIGN_IDENTITY"
    return
  fi

  local identity
  identity=$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F\" '/Apple Development:/{print $2; exit}'
  )

  if [[ -n "$identity" ]]; then
    echo "$identity"
  else
    echo "-"
  fi
}

write_info_plist() {
  cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>pt-PT</string>
  <key>CFBundleDisplayName</key>
  <string>Wishper Pro Dev</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Wishper Pro Dev</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0-dev</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Wishper Pro precisa de microfone para ditado.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
}

main() {
  cd "$ROOT_DIR"
  echo "[1/5] Building debug binary..."
  swift build

  local signing_identity
  signing_identity="$(detect_signing_identity)"
  echo "[2/5] Using signing identity: $signing_identity"

  echo "[3/5] Creating dev app bundle at $APP_PATH"
  rm -rf "$APP_PATH"
  mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
  cp ".build/debug/$EXECUTABLE_NAME" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
  chmod +x "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
  if [[ -f "$ICON_PATH" ]]; then
    cp "$ICON_PATH" "$APP_PATH/Contents/Resources/AppIcon.icns"
  fi
  write_info_plist

  echo "[4/5] Signing dev bundle..."
  codesign --force --deep --sign "$signing_identity" \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$APP_PATH"
  xattr -dr com.apple.quarantine "$APP_PATH" || true

  echo "[5/5] Opening dev app..."
  pkill -f 'WishperPro' || true
  open "$APP_PATH"

  echo "Done."
}

main "$@"
