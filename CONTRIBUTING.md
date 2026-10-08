# Contributing

Thanks for helping. Džep is small and opinionated, so for anything bigger than a fix, open an issue first so we can agree on the shape before you build it.

## Setup

[docs/BUILDING.md](docs/BUILDING.md) covers tools, your own signing identity (`config/Local.xcconfig`) and a local backend. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the pieces fit, and why some of them look odd.

## Pull requests

- Keep each PR to one change, and describe what a user will notice.
- Run `fvm flutter analyze`, `fvm flutter test` and `deno check supabase/functions/*/index.ts`; CI runs them too.
- Add a test when you change behavior that can quietly break: parsing, sync, reminders.
- Database changes go in a **new** migration in `supabase/migrations/`, timestamped after the latest. Never edit one that has shipped: self-hosters have already applied it.
- Note user-visible changes under **Unreleased** in `CHANGELOG.md`, and say whether self-hosters must rerun `tool/setup-backend.sh`.
- Don't commit anything from `config/Local.xcconfig` or `supabase/.env`.

## Style

Format Dart with `fvm dart format -l 120`. Comments explain *why*: the platform quirk, the race, the constraint.
