# Releasing the Mac app

Each release is a notarized DMG on GitHub Releases, plus an `appcast.xml` that installed copies check through Sparkle. `tool/release.sh` does all of it.

## One-time setup (maintainer's Mac)

1. **Developer ID certificate.** Xcode → Settings → Accounts → your team → Manage Certificates → **+** → Developer ID Application.
2. **Notarization credentials.** Create an app-specific password at [account.apple.com](https://account.apple.com), then:
   ```sh
   xcrun notarytool store-credentials dzep-notary --apple-id <you@example.com> --team-id <TEAM>
   ```
3. **Sparkle signing key.** The private half lives in the login keychain, and its public half is `SUPublicEDKey` in `macos/Runner/Info.plist`. Check it with `macos/Pods/Sparkle/bin/generate_keys -p`. **Back it up**: without it, installed copies won't accept new updates.
   ```sh
   macos/Pods/Sparkle/bin/generate_keys -x sparkle-private-key   # store this file somewhere safe, offline
   ```
4. `gh auth login`, with push access to the repo.

## Each release

1. Bump `version:` in `pubspec.yaml` (for example `0.2.0+2`; the build number must grow).
2. Add a `## 0.2.0` section to `CHANGELOG.md`. Say whether the backend needs `tool/setup-backend.sh` again: new migrations or function changes.
3. Commit, then:
   ```sh
   tool/release.sh
   ```

The script checks the prerequisites above, builds and archives the app, and exports it with Developer ID signing. It notarizes and staples the app, builds the DMG, and notarizes and staples that too. Then it writes the appcast (keeping older entries), tags `v<version>`, and creates the GitHub release with the DMG and `appcast.xml`.

`tool/release.sh --dry-run` runs the same build with development signing, without notarizing or publishing, and leaves `build/release/Dzep-<version>.dmg`.
