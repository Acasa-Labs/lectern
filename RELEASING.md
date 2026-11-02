# Releasing Folio

Releases are signed with a Developer ID certificate and notarized by Apple, so they open on any Mac without warnings.

## One-time setup

1. **Developer ID certificate.** Create a *Developer ID Application* certificate in your Apple Developer account. Use Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application. This needs the Account Holder role, or Admin with access to Developer ID certificates. Check that it's installed:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

2. **Notarization credentials.** Create an app-specific password at [account.apple.com](https://account.apple.com), then save it to your keychain:

   ```sh
   xcrun notarytool store-credentials folio-notary --apple-id you@example.com --team-id TEAMID
   ```

## Release from your Mac

1. Add the version's notes to [CHANGELOG.md](CHANGELOG.md) and commit.
2. Build, sign and notarize:

   ```sh
   scripts/release.sh 1.0.0
   ```

   This writes `dist/Folio-1.0.0.dmg` and `dist/Folio-1.0.0.dmg.sha256`. The build number is the commit count. To check signing without waiting for Apple, run `SKIP_NOTARIZE=1 scripts/release.sh 1.0.0`.
3. Tag the commit, push the tag, and publish the release with both files:

   ```sh
   git tag v1.0.0 && git push origin v1.0.0
   gh release create v1.0.0 dist/Folio-1.0.0.dmg dist/Folio-1.0.0.dmg.sha256 --title "Folio 1.0.0" --notes-file -
   ```

## Release from GitHub Actions

[`.github/workflows/release.yml`](.github/workflows/release.yml) runs when you push a `v*` tag. It builds, signs and notarizes the release, then opens a **draft** GitHub release. You review the draft and publish it.

The workflow runs in a GitHub environment named `release`. Add these secrets to that environment, and require approval for it, so only maintainers can sign:

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_P12` | The Developer ID certificate and its private key, exported from Keychain Access as .p12, then base64-encoded (`base64 -i cert.p12 \| pbcopy`). |
| `DEVELOPER_ID_P12_PASSWORD` | The password you set when exporting the .p12. |
| `NOTARY_KEY_P8` | The contents of an App Store Connect API key (.p8) with the Developer role. |
| `NOTARY_KEY_ID` | That key's ID. |
| `NOTARY_ISSUER` | Your App Store Connect issuer ID. |
