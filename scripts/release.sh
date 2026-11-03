#!/bin/sh
# Builds a signed, notarized Lectern release: dist/Lectern-<version>.dmg, its SHA-256, and the Sparkle feed dist/appcast.xml.
#
#   scripts/release.sh 1.0.0
#
# Needs a "Developer ID Application" certificate in your keychain and notarization credentials, either
#   NOTARY_PROFILE   a profile saved with `xcrun notarytool store-credentials` (default: lectern-notary), or
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER   an App Store Connect API key (.p8 path, key id, issuer id), as in CI.
# Sparkle updates are signed with an EdDSA key: SPARKLE_KEY_FILE (a key exported with generate_keys -x, as in CI),
# or else the key saved in your keychain under the account "lectern".
# SIGN_IDENTITY picks the certificate when you have more than one (default: "Developer ID Application").
# SKIP_NOTARIZE=1 signs without notarizing, to check the build quickly.
set -e
cd "$(dirname "$0")/.."

VERSION="$1"
case "$VERSION" in
    [0-9]*.[0-9]*) ;;
    *) echo "usage: $0 <version, e.g. 1.0.0>" >&2; exit 64 ;;
esac
BUILD="$(git rev-list --count HEAD)"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
DIST="dist"

if [ -n "$(git status --porcelain)" ]; then
    echo "warning: the working tree has uncommitted changes; they will be in this build." >&2
fi

echo "==> Building Lectern $VERSION ($BUILD) for Apple silicon and Intel"
BINARY="$(scripts/build-universal.sh)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$(scripts/assemble.sh "$BINARY" "$STAGE" "$VERSION" "$BUILD")"

echo "==> Signing with \"$IDENTITY\""
# Sparkle's helpers first, inside out, as Sparkle's docs describe (no --deep). Downloader keeps its entitlements.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements Lectern.entitlements "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

echo "==> Making the disk image"
mkdir -p "$DIST"
DMG="$DIST/Lectern-$VERSION.dmg"
rm -f "$DMG"
mkdir "$STAGE/dmg"
cp -R "$APP" "$STAGE/dmg/"
ln -s /Applications "$STAGE/dmg/Applications"
hdiutil create -quiet -volname "Lectern $VERSION" -srcfolder "$STAGE/dmg" -fs HFS+ -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ "$SKIP_NOTARIZE" = 1 ]; then
    echo "==> Skipping notarization (SKIP_NOTARIZE=1). This build will warn when opened on other Macs."
else
    echo "==> Notarizing (this usually takes a few minutes)"
    if [ -n "$NOTARY_KEY" ]; then
        xcrun notarytool submit "$DMG" --wait --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
    else
        xcrun notarytool submit "$DMG" --wait --keychain-profile "${NOTARY_PROFILE:-lectern-notary}"
    fi
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

(cd "$DIST" && shasum -a 256 "Lectern-$VERSION.dmg" > "Lectern-$VERSION.dmg.sha256")

echo "==> Making the update feed"
# Sparkle reads releases/latest/download/appcast.xml, so publishing a release is what offers it as an update.
# The feed holds this version only, with its CHANGELOG.md section as the notes shown in the update window.
FEED="$STAGE/feed"
mkdir "$FEED"
rm -f "$DIST/appcast.xml"
cp "$DMG" "$FEED/"
NOTES="$(awk -v v="$VERSION" '/^## / { on = ($2 == v); next } on && /^- / { sub(/^- /, ""); print "<li>" $0 "</li>" }' CHANGELOG.md)"
[ -n "$NOTES" ] && printf '<ul>\n%s\n</ul>\n' "$NOTES" > "$FEED/Lectern-$VERSION.html"
if [ -n "$SPARKLE_KEY_FILE" ]; then KEY="--ed-key-file $SPARKLE_KEY_FILE"; else KEY="--account lectern"; fi
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
    $KEY --embed-release-notes \
    --download-url-prefix "https://github.com/Acasa-Labs/lectern/releases/download/v$VERSION/" \
    --full-release-notes-url "https://github.com/Acasa-Labs/lectern/releases/tag/v$VERSION" \
    -o "$DIST/appcast.xml" "$FEED"
echo "==> $DMG and $DIST/appcast.xml"
cat "$DMG.sha256"
