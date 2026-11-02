#!/bin/sh
# Builds "Folio.app" and installs it to /Applications.
set -e
cd "$(dirname "$0")"

swift build -c release
# Assembled in a temp folder so Spotlight never sees a second copy of the app.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Folio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/* "$APP/Contents/Resources/"
cp .build/release/Folio "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
touch "$APP"
codesign --force --sign - "$APP"

rm -rf "/Applications/Folio.app"
cp -R "$APP" /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Folio.app"
echo "Installed /Applications/Folio.app"
