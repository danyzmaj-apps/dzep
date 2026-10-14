# Džep for Mac

The menu-bar app: the ⇧⌘Space popup, the main and note windows, the Todos widget, the local terminal API, the bridge that lets a phone reach omp, Claude Code and the Mac's terminals (kitty, tmux, WezTerm, iTerm2, Terminal, Ghostty), and the setup wizard that creates a user's server.

It also carries the backend, because the wizard bundles it as app assets and deploys it:

| Path | What |
| --- | --- |
| `lib/` | Flutter app (shared code comes from [`packages/dzep_core`](../../packages/dzep_core/)) |
| `macos/` | Xcode project: Runner (popup panel, hotkey, menu bar, notifications) and the `DzepWidget` extension |
| `supabase/migrations/` | The database schema; add a new file, never edit a shipped one |
| `supabase/functions/` | Edge functions: `ask`, `device`, `pair`, `push` (every user's server) and `relay` (the publisher's push relay only) |
| `tool/setup-backend.sh` | Set up or update a server from a terminal |
| `tool/deploy-relay.sh` | Deploy the publisher's push relay (APNs and FCM) |
| `tool/release.sh` | Build, notarize and publish a release |
| `tool/make_icon.swift` | Draw the app icons |
| `integrations/omp/` | omp extensions: `idea.ts` (`/idea`, `/do`, `/note`) and `live.ts` (sessions for the phone) |
| `integrations/claude/` | Claude Code marketplace with Džep's `dzep` plugin: `/idea`, `/do`, `/note` and sessions for the phone (`plugins/dzep/hooks/`); `claude plugin test integrations/claude/plugins/dzep` runs its tests |
| `test/screenshots/` | The docs' Mac screenshots (popup, main window, Settings, setup wizard) and the hero's popup, rendered on made-up data ([BUILDING.md](../../docs/BUILDING.md#screenshots)) |

Run it from this directory:

```sh
fvm flutter run -d macos
```

See [docs/BUILDING.md](../../docs/BUILDING.md), [docs/RELEASING.md](../../docs/RELEASING.md) and [docs/SELF_HOSTING.md](../../docs/SELF_HOSTING.md).
