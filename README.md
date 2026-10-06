# Ideja

A personal inbox for dev ideas: one keystroke on the Mac, one sentence to Siri on the iPhone, synced through Supabase.

- **Mac**: a menu-bar app. ⇧⌘Space opens a Spotlight-style popup with the cursor in the field; ↵ saves to Inbox. The main window (menu-bar icon → right-click, or ⌘O in the popup) is where you triage: Inbox → Building → Shipped / Dropped, projects, descriptions.
- **iPhone**: list, filters, search, a + button; "Hey Siri, add an idea to Ideja" (or the Action Button) saves without opening the app; a Home / Lock Screen widget opens straight into the add sheet.
- **Terminal**: omp's `/idea` (`~/.omp/agent/extensions/idea.ts`) files ideas under the current repo's name via the Mac app's localhost API.

The design mockup is `design/mockup.html`.

## Layout

| Path | What |
| --- | --- |
| `lib/session.dart` | GitHub sign-in and the user's `IdeaStore` (shared) |
| `lib/store.dart` | Local JSON cache + Supabase sync (push dirty, pull since cursor, realtime) |
| `lib/controller.dart`, `popup.dart`, `main_window.dart`, `native.dart` | Mac app |
| `lib/local_api.dart` | Mac: 127.0.0.1 API for `/idea` |
| `lib/mobile.dart` | iPhone app |
| `macos/Runner/MainFlutterWindow.swift` | Mac window shapes, menu-bar icon, Carbon hotkey, launch at login |
| `ios/Runner/AddIdeaIntent.swift` | Siri / Action Button intent |
| `ios/IdejaWidget/` | WidgetKit extension |
| `supabase/` | Migrations and the `add-idea` edge function |
| `maestro/` | Simulator flows |

## Backend

Supabase project `ideja` (`tgqmhieundubwtyvsnih`, eu-central-1).

- `ideas`: one row per idea; ids are client-generated so capture works offline; deletes are soft (`deleted_at`) so other devices learn about them; `updated_at` is set by a trigger (the sync cursor). RLS: own rows only.
- `device_tokens`: SHA-256 of per-iPhone tokens. The Siri intent can't reach the app's session, so it calls `functions/v1/add-idea` with `x-ideja-token`; the function maps the token to the user. Deployed with `--no-verify-jwt`.
- Auth: GitHub OAuth app owned by `danyzmaj-apps`; redirect `ideja://login-callback`.

```sh
supabase db push                                  # migrations
supabase functions deploy add-idea --no-verify-jwt
```

## Terminal API (Mac)

On launch the Mac app listens on a random 127.0.0.1 port and writes `{port, token}` to `~/.config/ideja/cli.json` (mode 600).

```
GET   /v1/ideas?project=NAME     → {"ideas": [...]}  oldest first
POST  /v1/ideas                  {title, notes?, project?}
PATCH /v1/ideas/ID               {status}
Authorization: Bearer <token>
```

## Run

```sh
fvm flutter run -d macos
fvm flutter run -d ios
```

Signing: team `5SSZ6TYMF5` (Danijel Lovric) on every target. The Mac app is not sandboxed (global hotkey, `~/.config` file, loopback server).

## Tests

Maestro flows need a signed-in simulator:

```sh
maestro test -e TS=$(date +%H%M%S) maestro/
```
