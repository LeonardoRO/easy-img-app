#!/bin/bash
# Builds "Easy Img.app" into ./build.
#   --install  also copies it to /Applications and registers it with Finder (Open With, Services).
#   --release  also creates build/Easy-Img-<version>.dmg for distribution. With a "Developer ID Application"
#              certificate and a notarytool profile (NOTARY_PROFILE, default "easyimg"), the DMG is signed,
#              notarized by Apple and stapled, so it opens on any Mac without warnings.
# Signing uses SIGN_IDENTITY if set, else the best certificate found: Developer ID Application,
# then Apple Development (a stable identity, so the keychain stops asking after every rebuild), then ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Easy Img"
EXECUTABLE="EasyImg"
BUILD="build"
APP="$BUILD/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
NOTARY_PROFILE="${NOTARY_PROFILE:-easyimg}"
MODE="${1:-}"

find_identity() {
  security find-identity -v -p codesigning | grep -o "\"$1: [^\"]*\"" | head -1 | tr -d '"' || true
}
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(find_identity "Developer ID Application")"
  [[ -z "$IDENTITY" ]] && IDENTITY="$(find_identity "Apple Development")"
  [[ -z "$IDENTITY" ]] && IDENTITY="-"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -sdk "$SDK" -target "$arch-apple-macos14.0" \
    Sources/*.swift -o "$BUILD/$EXECUTABLE-$arch"
done
lipo -create "$BUILD/$EXECUTABLE-arm64" "$BUILD/$EXECUTABLE-x86_64" -output "$APP/Contents/MacOS/$EXECUTABLE"
rm "$BUILD/$EXECUTABLE-arm64" "$BUILD/$EXECUTABLE-x86_64"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Help.html "$APP/Contents/Resources/Help.html"

if [[ ! -f "$BUILD/AppIcon.icns" ]]; then
  rm -rf "$BUILD/AppIcon.iconset"
  swift scripts/make-icon.swift "$BUILD/AppIcon.iconset"
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Hardened runtime: blocks code injection (DYLD_* variables, unsigned libraries) into the app.
# Developer ID signatures need a secure timestamp for notarization.
TIMESTAMP=()
[[ "$IDENTITY" == "Developer ID Application:"* ]] && TIMESTAMP=(--timestamp)
codesign --force --options runtime "${TIMESTAMP[@]+"${TIMESTAMP[@]}"}" --sign "$IDENTITY" "$APP"
echo "Built $APP (signed: ${IDENTITY/#-/ad-hoc})"

if [[ "$MODE" == "--install" ]]; then
  DEST="/Applications/$APP_NAME.app"
  pkill -x "$EXECUTABLE" 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  /System/Library/CoreServices/pbs -update
  echo "Installed $DEST"
fi

if [[ "$MODE" == "--release" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
  DMG="$BUILD/Easy-Img-$VERSION.dmg"
  STAGE="$BUILD/dmg"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
  rm -rf "$STAGE"

  if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
      echo "No notarytool profile \"$NOTARY_PROFILE\". Create it once with:" >&2
      echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id <team-id>" >&2
      exit 1
    fi
    echo "Submitting to Apple for notarization (usually 1-5 minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
    echo "Release ready: $DMG (signed, notarized and stapled)"
  else
    echo "Release created: $DMG"
    echo "WARNING: not notarized (no \"Developer ID Application\" certificate). Other Macs will block it until"
    echo "the user allows it in System Settings → Privacy & Security → Open Anyway."
  fi
fi
