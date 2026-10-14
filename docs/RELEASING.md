# Releasing

Maintainer notes for shipping the three builds: the Mac app (notarized DMG on GitHub Releases, updated through Sparkle), the iPhone app (TestFlight, then the App Store) and the Android app (Google Play). Plus the push relay they all depend on.

Every app's version is the `version:` line of its own `pubspec.yaml` (`apps/dzep-macos-app/pubspec.yaml`, `apps/dzep-mobile/pubspec.yaml`), as `<name>+<build>`. The build number must grow with every upload to any store; keep both apps on the same version name.

## Push relay (once, and after relay changes)

Every user's server sends phone notifications through one relay the publisher runs, `functions/relay` on the publisher's own Supabase project. It holds the only credentials that can reach Džep's installs: the APNs key for iPhones and the Firebase service account for Android.

1. **APNs key.** At [developer.apple.com → Keys](https://developer.apple.com/account/resources/authkeys/add), create a key with Apple Push Notifications service (Sandbox & Production, team scoped). The `.p8` downloads once: keep it in the maintainer's keys folder, never in the repo.
2. **Firebase service account.** In the Firebase project that holds the Android app (package `com.danyzmaj.dzep`), Project settings → Service accounts → **Generate new private key**. Keep the JSON next to the `.p8`, never in the repo. The same project's `google-services.json` goes into Android release builds (below).
3. **Deploy** (in `apps/dzep-macos-app`):
   ```sh
   tool/deploy-relay.sh <project-ref> <path>/AuthKey_<KEYID>.p8 <TEAM> [bundle-id] [--fcm <path>/firebase-service-account.json]
   ```
   It stores the APNs key as relay secrets, with `--fcm` the service account as the `FCM_SERVICE_ACCOUNT` secret, and deploys `relay`. Without a service account the relay answers Android pushes with 501.

`functions/push` on every server points at `https://<project-ref>.supabase.co/functions/v1/relay` (`PUSH_RELAY_URL`); change its default if the relay moves.

## Mac

Each release is a notarized DMG on GitHub Releases, plus an `appcast.xml` that installed copies check through Sparkle. `tool/release.sh` does all of it.

### One-time setup (maintainer's Mac)

1. **Developer ID Application certificate.** Xcode → Settings → Accounts → your team → Manage Certificates → **+** → Developer ID Application.
2. **Notarization credentials.** Create an app-specific password at [account.apple.com](https://account.apple.com), then store them as the keychain profile `dzep-notary`:
   ```sh
   xcrun notarytool store-credentials dzep-notary --apple-id <you@example.com> --team-id <TEAM>
   ```
3. **Sparkle signing key.** The private half lives in the login keychain; its public half is `SUPublicEDKey` in `apps/dzep-macos-app/macos/Runner/Info.plist`. Check it (in `apps/dzep-macos-app`) with `macos/Pods/Sparkle/bin/generate_keys -p`. **Back it up**: without it, installed copies won't accept new updates.
   ```sh
   # in apps/dzep-macos-app; write it straight to your keys folder, never into the repo
   macos/Pods/Sparkle/bin/generate_keys -x <keys-folder>/dzep-sparkle-private-key && chmod 600 <keys-folder>/dzep-sparkle-private-key
   ```
4. `gh auth login`, with push access to the repo.

**A fork shipping its own Mac app** makes its own Sparkle key the same way, puts its public half in `SUPublicEDKey` and its own feed in `SUFeedURL` (`https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`, same `Info.plist`), and runs `release.sh` with `REPO=<owner>/<repo>`. Otherwise its copies would look for updates from upstream and refuse them. Its team and bundle id come from `config/Local.xcconfig` ([BUILDING.md](BUILDING.md#your-signing-identity)), its push relay from `PUSH_RELAY_URL` ([SELF_HOSTING.md](SELF_HOSTING.md#your-own-app-id-and-relay)).

### Each release

1. Bump `version:` in `apps/dzep-macos-app/pubspec.yaml` (for example `0.3.0+3`).
2. Turn **Unreleased** in `CHANGELOG.md` into a `## 0.3.0` section. Say whether servers need `tool/setup-backend.sh` again (new migrations or function changes) and whether the relay must be redeployed.
3. Commit, then (in `apps/dzep-macos-app`):
   ```sh
   tool/release.sh
   ```

The script checks the prerequisites above, builds and archives the app, and exports it with Developer ID signing. It notarizes and staples the app, builds the DMG, and notarizes and staples that too. Then it writes the appcast (keeping older entries), tags `v<version>`, and creates the GitHub release with the DMG and `appcast.xml`.

`tool/release.sh --dry-run` runs the same build with development signing, without notarizing or publishing, and leaves `build/release/Dzep-<version>.dmg` (in `apps/dzep-macos-app`).

## iPhone

### One-time setup

1. An **App Store Connect** record for bundle id `com.danyzmaj.dzep` (the id in `config/Dzep.xcconfig`), with the App Group and the widget and push extension targets' ids registered (automatic signing does this on the first `-allowProvisioningUpdates` build, see [BUILDING.md](BUILDING.md)).
2. App privacy answers, a privacy policy URL, screenshots and a support URL in App Store Connect.
3. **App Review sign-in.** The phone app signs in only with a code from the Mac (no GitHub, so guideline 4.8's Sign in with Apple doesn't apply). For the reviewers, on the Mac: **Settings → Reviewer access → Codes…**, 90 days, label "App Store review". In App Store Connect → App Review Information, put in the notes: "There is no user name or password. Open Džep, tap **Paste a code instead**, paste this link, tap **Sign in**:" followed by the link (**Copy**), and attach the QR (**Save QR as PNG**). It signs into a demo account on your server that sees none of your data. Make a new code before it expires, and revoke old ones.

### Each release

```sh
# in apps/dzep-mobile
fvm flutter build ipa --release        # → build/ios/ipa/*.ipa
```

Upload it with Xcode's Organizer or Transporter (or archive `ios/Runner.xcworkspace` in Xcode: Product → Archive → Distribute App → App Store Connect). Release it to TestFlight testers first; submit the same build for App Store review once it has been tried.

Pushes from TestFlight and App Store builds use APNs production; the relay handles both production and sandbox tokens.

## Android

### One-time setup

1. A **Google Play Console** developer account and an app with package `com.danyzmaj.dzep`.
2. **Play App Signing** (the default for new apps): Google holds the app signing key; we sign uploads with an **upload key**. The upload keystore is `dzep-upload.jks` (alias `upload`) in the maintainer's keys folder, its password in the maintainer's Keychain. It is never committed. If it is lost, request an upload key reset in Play Console.
3. `apps/dzep-mobile/android/key.properties` (git-ignored, from `key.properties.example`) points at that keystore.
4. `apps/dzep-mobile/android/app/google-services.json` (git-ignored) from the Firebase project whose service account the relay holds. A release without it has no push.
5. Play Console: store listing, privacy policy URL, data safety form, content rating, target audience, and the notification permission declaration.
6. Play Console → App content → **App access**: "All or some functionality is restricted", with the same instructions and a reviewer code of its own (label "Play review"), as for App Review above.

### Each release

```sh
# in apps/dzep-mobile
fvm flutter build appbundle --release   # → build/app/outputs/bundle/release/app-release.aab
```

Upload the `.aab` to the **Internal testing** track, try it, then promote the same release to **Production** (new personal developer accounts must run a closed test first; Play Console says how long).
