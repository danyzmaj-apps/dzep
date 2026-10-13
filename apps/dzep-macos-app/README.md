# Džep for Mac

The menu-bar app: the ⇧⌘Space popup, the main and note windows, the Todos widget, the local terminal API, the bridge that lets a phone reach omp and kitty, and the setup wizard that creates a user's server.

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
| `integrations/omp/` | omp extensions: `idea.ts` (`/idea`, `/todo`, `/note`) and `live.ts` (sessions for the phone) |

Run it from this directory:

```sh
fvm flutter run -d macos
```

See [docs/BUILDING.md](../../docs/BUILDING.md), [docs/RELEASING.md](../../docs/RELEASING.md) and [docs/SELF_HOSTING.md](../../docs/SELF_HOSTING.md).
