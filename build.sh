#!/bin/zsh
# Builds Encore.app into ./build and signs it ad hoc for local use.
set -e
cd "$(dirname "$0")"
ARCHS=(--arch arm64 --arch x86_64)  # universal: Apple silicon and Intel
swift build -c release $ARCHS
BIN=$(swift build -c release $ARCHS --show-bin-path)
APP=build/Encore.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Encore" "$APP/Contents/MacOS/Encore"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"
