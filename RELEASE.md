# Release Engineering

PDFViewer 1.0 uses App Sandbox, user-selected read/write access, hardened runtime, a stable Release configuration, PDF file association, and bundle identifier `com.christopherrego.PDFViewer`.

## Local release candidate

Run:

```sh
./scripts/package-release.sh
```

This performs a clean Release archive, copies the app into an isolated staging directory, signs it, verifies the signature and entitlements, creates `dist/PDFViewer-1.0.0.dmg`, and writes a SHA-256 checksum. Without `CODE_SIGN_IDENTITY`, the signature is ad hoc and suitable only for local QA.

## Developer ID distribution

1. Install an Apple `Developer ID Application` certificate in the signing Keychain.
2. Store notarization credentials outside the repository:

   ```sh
   xcrun notarytool store-credentials PDFViewer \
     --apple-id YOUR_APPLE_ID \
     --team-id YOUR_TEAM_ID \
     --password YOUR_APP_SPECIFIC_PASSWORD
   ```

3. Package, sign, notarize, staple, and validate:

   ```sh
   CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
   NOTARY_PROFILE=PDFViewer \
   ./scripts/package-release.sh
   ```

4. Install the DMG from a fresh macOS user account, open PDFs through Finder and Open With, exercise drag-and-drop and export permissions, then run `spctl --assess --type execute --verbose` on the installed app.

## Rollback

Keep each versioned DMG and checksum immutable. Do not overwrite an existing artifact; the packaging script refuses unless `OVERWRITE=1` is explicitly supplied. Retain the previous notarized release until the new build passes clean-account smoke testing.

## Current credential state

Apple signing certificates and notarization credentials are intentionally machine/operator secrets. They are not present in source control, unit tests, CI logs, or app resources.
