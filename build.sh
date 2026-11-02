#!/bin/sh
# Builds Lectern.app for this Mac, signs it ad hoc and installs it to /Applications.
# For a signed, notarized release use scripts/release.sh.
set -e
cd "$(dirname "$0")"

swift build -c release
# Assembled in a temp folder so Spotlight never sees a second copy of the app.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$(scripts/assemble.sh .build/release/Lectern "$STAGE")"
codesign --force --sign - --entitlements Lectern.entitlements "$APP"

rm -rf "/Applications/Lectern.app"
cp -R "$APP" /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Lectern.app"
echo "Installed /Applications/Lectern.app"
