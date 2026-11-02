#!/bin/sh
# Puts Lectern.app together from a built binary: scripts/assemble.sh <binary> <output folder> [version] [build]
# Shared by build.sh (local install) and release.sh (signed releases).
set -e
cd "$(dirname "$0")/.."

BINARY="$1"
OUT="$2"
VERSION="$3"
BUILD="$4"
[ -n "$BINARY" ] && [ -n "$OUT" ] || { echo "usage: $0 <binary> <output folder> [version] [build]" >&2; exit 64; }

APP="$OUT/Lectern.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/* "$APP/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp "$BINARY" "$APP/Contents/MacOS/Lectern"
cp Info.plist "$APP/Contents/"
if [ -n "$VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "$BUILD" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
fi
touch "$APP"
echo "$APP"
