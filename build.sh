#!/bin/sh
# Builds Folio.app for this Mac, signs it ad hoc and installs it to /Applications.
# For a signed, notarized release use scripts/release.sh.
set -e
cd "$(dirname "$0")"

swift build -c release
# Assembled in a temp folder so Spotlight never sees a second copy of the app.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$(scripts/assemble.sh .build/release/Folio "$STAGE")"
codesign --force --sign - --entitlements Folio.entitlements "$APP"

rm -rf "/Applications/Folio.app"
cp -R "$APP" /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Folio.app"
echo "Installed /Applications/Folio.app"
