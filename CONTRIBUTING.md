# Contributing

Thanks for helping. Džep is small and opinionated, so for anything bigger than a fix, open an issue first so we can agree on the shape before you build it.

## Setup

[docs/BUILDING.md](docs/BUILDING.md) covers tools, your own signing identity (`config/Local.xcconfig`, Android `key.properties`) and a local backend. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the pieces fit, and why some of them look odd.

The repo is a pub workspace: `apps/dzep-macos-app` (Mac app and the backend), `apps/dzep-mobile` (iPhone and Android), `packages/dzep_core` (shared). Code both apps use belongs in `dzep_core`. A change to the phone app should work on both iPhone and Android; if one platform can't do it (like Siri), say so in the PR.

## Pull requests

- Keep each PR to one change, and describe what a user will notice.
- Run the checks; CI runs them too:
  ```sh
  # in each of packages/dzep_core, apps/dzep-macos-app, apps/dzep-mobile
  fvm dart format --set-exit-if-changed lib test
  fvm flutter analyze
  fvm flutter test
  # at the repo root
  deno check apps/dzep-macos-app/supabase/functions/*/index.ts
  # in apps/dzep-macos-app (Docker)
  supabase db start && supabase db lint --level error
  # the Claude Code plugin, locally (CI can't: Claude Code mods need a logged-in claude)
  claude plugin validate . && claude plugin test plugins/dzep
  ```
- Add a test when you change behavior that can quietly break: parsing, sync, reminders.
- Database changes go in a **new** migration in `apps/dzep-macos-app/supabase/migrations/`, timestamped after the latest. Never edit one that has shipped: self-hosters have already applied it.
- Note user-visible changes under **Unreleased** in `CHANGELOG.md`, and say whether self-hosters must rerun `apps/dzep-macos-app/tool/setup-backend.sh`.
- Never commit `config/Local.xcconfig`, `apps/dzep-macos-app/supabase/.env*`, `apps/dzep-mobile/android/key.properties`, `google-services.json`, keystores or any key.

## Style

Format Dart with `fvm dart format -l 120`. Comments explain *why*: the platform quirk, the race, the constraint.
