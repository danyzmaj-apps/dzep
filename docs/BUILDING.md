# Building from source

## Tools

- Xcode 26 or newer, with your Apple ID signed in (Xcode → Settings → Accounts)
- [fvm](https://fvm.app): the Flutter version is pinned in `.fvmrc` (`fvm install` fetches it)
- CocoaPods: `brew install cocoapods`
- For the backend: the Supabase CLI and Docker (only to run Supabase locally)

```sh
fvm install
fvm flutter pub get   # at the repo root: resolves the whole workspace
```

The repo is a Dart pub workspace: the Mac app in `apps/dzep-macos-app`, the iPhone app in `apps/dzep-mobile`, the shared code in `packages/dzep_core`. Run each app's commands in its own directory.

## Your signing identity

Every Xcode target takes its team, bundle id and App Group from [config/Dzep.xcconfig](../config/Dzep.xcconfig). The values there belong to the upstream project, and Apple only lets their owner sign with them. To build under your own account:

```sh
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

## iPhone

The iPhone app has no public build: install it on your own phone from source. It needs a **paid** Apple Developer account, because its widget and Siri intents share data through an App Group.

```sh
cd apps/dzep-mobile
open ios/Runner.xcworkspace   # once: pick your phone, let Xcode register the device
fvm flutter run -d <your-iphone> --release
```

Then scan the Mac's setup code with it, or open your setup link on the phone ([SELF_HOSTING.md](SELF_HOSTING.md#connect-the-apps)).

## Backend, locally

```sh
cd apps/dzep-macos-app                           # the backend lives with the Mac app, which bundles it for its setup wizard
supabase start                                   # Docker; applies supabase/migrations
supabase functions serve --no-verify-jwt --env-file supabase/.env.local
```

`apps/dzep-macos-app/supabase/.env.local` (git-ignored) holds `AI_API_KEY` and the other `AI_*` settings for the functions. Point the app at `http://127.0.0.1:54321` with the local publishable key from `supabase status`. GitHub sign-in against a local stack needs a second OAuth app whose callback is `http://127.0.0.1:54321/auth/v1/callback`, with its id and secret in `apps/dzep-macos-app/supabase/.env`.

## Checks

```sh
# in each of packages/dzep_core, apps/dzep-macos-app, apps/dzep-mobile:
fvm flutter analyze
fvm flutter test
# at the root:
deno check apps/dzep-macos-app/supabase/functions/*/index.ts
```

CI runs the same checks on every pull request (`.github/workflows/ci.yml`).

[Maestro](https://maestro.mobile.dev) flows drive the iOS simulator app. They need a simulator signed in to a test backend, and `ask.yaml` needs an AI key there. Set `appId` in each flow to your bundle id.

```sh
maestro test -e TS=$(date +%H%M%S) apps/dzep-mobile/maestro/
```
