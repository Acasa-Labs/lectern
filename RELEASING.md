# Releasing Lectern

Releases are signed with a Developer ID certificate and notarized by Apple, so they open on any Mac without warnings.

## One-time setup

1. **Developer ID certificate.** Create a *Developer ID Application* certificate in your Apple Developer account. Use Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application. This needs the Account Holder role, or Admin with access to Developer ID certificates. Check that it's installed:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

2. **Update signing key.** Sparkle only installs updates signed with Lectern's EdDSA key. Its public half is `SUPublicEDKey` in [Info.plist](Info.plist); the private half lives in the login keychain of the Mac that made it, under the account `lectern`. Back it up somewhere safe, because losing it means existing installs can no longer update:

   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account lectern -x lectern-sparkle.key
   ```

   (`swift package resolve` downloads the Sparkle tools first.) To sign on another Mac, import it there with `generate_keys --account lectern -f lectern-sparkle.key`.

3. **Notarization credentials.** Create an app-specific password at [account.apple.com](https://account.apple.com), then save it to your keychain:

   ```sh
   xcrun notarytool store-credentials lectern-notary --apple-id you@example.com --team-id TEAMID
   ```

## Release from your Mac

1. Add the version's notes to [CHANGELOG.md](CHANGELOG.md) and commit.
2. Build, sign and notarize:

   ```sh
   scripts/release.sh 1.0.0
   ```

   This writes `dist/Lectern-1.0.0.dmg`, `dist/Lectern-1.0.0.dmg.sha256` and the update feed `dist/appcast.xml`, whose release notes come from the version's CHANGELOG section. The build number is the commit count. To check signing without waiting for Apple, run `SKIP_NOTARIZE=1 scripts/release.sh 1.0.0`.
3. Tag the commit, push the tag, and publish the release with all three files:

   ```sh
   git tag v1.0.0 && git push origin v1.0.0
   gh release create v1.0.0 dist/Lectern-1.0.0.dmg dist/Lectern-1.0.0.dmg.sha256 dist/appcast.xml --title "Lectern 1.0.0" --notes-file -
   ```

## Release from GitHub Actions

[`.github/workflows/release.yml`](.github/workflows/release.yml) runs when you push a `v*` tag. It builds, signs and notarizes the release, then opens a **draft** GitHub release. You review the draft and publish it. Installed copies look for `releases/latest/download/appcast.xml`, so publishing the release is what offers the update to them.

The workflow runs in a GitHub environment named `release`. Add these secrets to that environment, and require approval for it, so only maintainers can sign:

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_P12` | The Developer ID certificate and its private key, exported from Keychain Access as .p12, then base64-encoded (`base64 -i cert.p12 \| pbcopy`). |
| `DEVELOPER_ID_P12_PASSWORD` | The password you set when exporting the .p12. |
| `NOTARY_KEY_P8` | The contents of an App Store Connect API key (.p8) with the Developer role. |
| `NOTARY_KEY_ID` | That key's ID. |
| `NOTARY_ISSUER` | Your App Store Connect issuer ID. |
| `SPARKLE_ED_KEY` | The update signing key, as exported by `generate_keys -x` (one line of base64). |
