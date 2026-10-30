#!/bin/bash
# Builds "Easy Img.app" into ./build. Pass --install to copy it to /Applications
# and register it with Finder (Open With, Services).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Easy Img"
EXECUTABLE="EasyImg"
BUILD="build"
APP="$BUILD/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -sdk "$SDK" -target "$arch-apple-macos14.0" \
    Sources/*.swift -o "$BUILD/$EXECUTABLE-$arch"
done
lipo -create "$BUILD/$EXECUTABLE-arm64" "$BUILD/$EXECUTABLE-x86_64" -output "$APP/Contents/MacOS/$EXECUTABLE"
rm "$BUILD/$EXECUTABLE-arm64" "$BUILD/$EXECUTABLE-x86_64"

cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f "$BUILD/AppIcon.icns" ]]; then
  rm -rf "$BUILD/AppIcon.iconset"
  swift scripts/make-icon.swift "$BUILD/AppIcon.iconset"
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/$APP_NAME.app"
  pkill -x "$EXECUTABLE" 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  /System/Library/CoreServices/pbs -update
  echo "Installed $DEST"
fi
