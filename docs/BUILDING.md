# Building from source

## Tools

- Xcode 26 or newer, with your Apple ID signed in (Xcode → Settings → Accounts), for the Mac and iPhone apps
- [fvm](https://fvm.app): the Flutter version is pinned in `.fvmrc` (`fvm install` fetches it)
- CocoaPods: `brew install cocoapods`
- For Android: [Android Studio](https://developer.android.com/studio) (or the command-line Android SDK) with a JDK 17; `fvm flutter doctor` says what's missing
- For the backend: the Supabase CLI and Docker (only to run Supabase locally)

```sh
# at the repo root
fvm install
fvm flutter pub get   # resolves the whole workspace
```

The repo is a Dart pub workspace: the Mac app in `apps/dzep-macos-app`, the phone app (iPhone and Android) in `apps/dzep-mobile`, the shared code in `packages/dzep_core`. Each command below says which directory it runs in.

## Your signing identity

Every Xcode target takes its team, bundle id and App Group from [config/Dzep.xcconfig](../config/Dzep.xcconfig). The values there belong to the upstream project, and Apple only lets their owner sign with them. To build under your own account:

```sh
# at the repo root
cp config/Local.xcconfig.example config/Local.xcconfig   # git-ignored
```

Then set your own values in it:

- `DZEP_TEAM`: your team id (developer.apple.com → Membership).
- `DZEP_BUNDLE_ID`: any id you own, like `com.yourname.dzep`.
- `DZEP_APP_GROUP`: `group.` + your bundle id.

Automatic signing registers the ids and the App Group the first time you build with `-allowProvisioningUpdates` (below).

## Mac

```sh
cd apps/dzep-macos-app
fvm flutter run -d macos
```

The first time, and whenever a provisioning profile expires (yearly), let Xcode fetch profiles once; `flutter run` doesn't:

```sh
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -allowProvisioningUpdates build   # in apps/dzep-macos-app
```

A free Apple ID can build and run the Mac app for yourself. Notarized releases need a paid account ([RELEASING.md](RELEASING.md)).

### Running a second Džep for testing

A debug build next to the Džep you use shares more than its code. Built with the same bundle id, it reads and writes the same preferences and App Group (account, widget data), and by default both write `~/.config/dzep/cli.json` (the terminal API's port and token) and talk to the kitty behind `/tmp/kitty*`. To keep a test run apart:

```sh
# in apps/dzep-macos-app
mkdir -p /tmp/dzep-e2e
DZEP_CLI_JSON=/tmp/dzep-e2e/cli.json DZEP_KITTY_DIR=/tmp/dzep-e2e fvm flutter run -d macos
```

- `DZEP_CLI_JSON`: the file it writes its port and token to. omp's extensions and the Claude Code plugin read the same variable, so start the omp or `claude` you test with under it too.
- `DZEP_KITTY_DIR`: the directory whose `kitty*` sockets it uses for Terminal from phone. Give it a kitty of its own: `kitty -o allow_remote_control=socket-only -o listen_on=unix:/tmp/dzep-e2e/kitty`.
- Preferences: the simple way is to quit the installed Džep while the test build runs. To run both at once, set another `DZEP_BUNDLE_ID` and `DZEP_APP_GROUP` in `config/Local.xcconfig` ([above](#your-signing-identity)). Xcode must register the new ids and App Group with your team first: build once with the `xcodebuild … -allowProvisioningUpdates` line above (or from Xcode). Until then `flutter run` and `flutter build macos` fail with "No profiles for '<id>'".

## iPhone

Install it on your own phone from source until the TestFlight build is out. It needs a **paid** Apple Developer account, because its widgets and Siri intents share data through an App Group.

```sh
cd apps/dzep-mobile
open ios/Runner.xcworkspace   # once: pick your phone, let Xcode register the device
fvm flutter run -d <your-iphone> --release
```

Then pair it: on the Mac, **Settings → Set up phone…**, and scan the code with the app ([SELF_HOSTING.md](SELF_HOSTING.md#connect-the-apps)).

## Android

```sh
cd apps/dzep-mobile
fvm flutter run -d <your-android-device>          # debug build, debug signing
fvm flutter build apk --release                   # → build/app/outputs/flutter-apk/app-release.apk
fvm flutter build appbundle --release             # → build/app/outputs/bundle/release/app-release.aab (for Google Play)
```

**Release signing.** Release builds are signed with an upload key described in `apps/dzep-mobile/android/key.properties` (git-ignored); a release build without it fails. Start from the example:

```sh
# in apps/dzep-mobile
cp android/key.properties.example android/key.properties
```

and point it at your own keystore (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`). To make one:

```sh
keytool -genkeypair -v -keystore ~/keys/dzep-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Keep the keystore and its password outside the repo.

**Push (optional).** Android push goes through Firebase Cloud Messaging. Put your Firebase project's `google-services.json` (Firebase console → Project settings → your Android app, package `com.danyzmaj.dzep` or your own) in `apps/dzep-mobile/android/app/` (git-ignored). Without it the app builds and works, push is off, and reminders are scheduled on the phone instead. Pushes only arrive if the relay your server uses holds the service account of that same Firebase project ([SELF_HOSTING.md](SELF_HOSTING.md#your-own-app-id-and-relay)).

**Your own package name.** The application id is `com.danyzmaj.dzep` in `apps/dzep-mobile/android/app/build.gradle.kts`. Google Play needs it to be unique, so a fork that publishes changes it there (and registers that id in its Firebase project).

Then pair the phone as above.

## Backend, locally

```sh
cd apps/dzep-macos-app                           # the backend lives with the Mac app, which bundles it for its setup wizard
supabase start                                   # Docker; applies supabase/migrations
supabase functions serve --no-verify-jwt --env-file supabase/.env.local
```

`apps/dzep-macos-app/supabase/.env.local` (git-ignored) holds `AI_API_KEY` and the other `AI_*` settings for the functions. Point the app at `http://127.0.0.1:54321` with the local publishable key from `supabase status`. GitHub sign-in against a local stack needs a second OAuth app whose callback is `http://127.0.0.1:54321/auth/v1/callback`, with its id and secret in `apps/dzep-macos-app/supabase/.env`.

## Checks

The checks to run before a pull request, and which of them CI runs (`.github/workflows/ci.yml`), are listed in [CONTRIBUTING.md](../CONTRIBUTING.md#pull-requests).

[Maestro](https://maestro.mobile.dev) flows drive the iOS simulator app. They need a simulator signed in to a test backend, and `ask.yaml` needs an AI key there. Set `appId` in each flow to your bundle id.

```sh
maestro test -e TS=$(date +%H%M%S) apps/dzep-mobile/maestro/
```
