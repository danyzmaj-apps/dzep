# Džep

A personal pocket for dev ideas and work todos: one keystroke on the Mac, one sentence to Siri on the iPhone, synced through Supabase.

- **Mac**: a menu-bar app. ⇧⌘Space opens a chooser: **1** idea, **2** todo, **3** open the app. The field is focused right away; ↵ saves. The menu-bar icon shows the open-todo count. The main window has Todos (open / done) and Ideas (Inbox → Building → Shipped / Dropped, projects, descriptions).
- **iPhone**: Todos and Ideas tabs, a + button, swipe right to tick a todo off. "Hey Siri, add a todo / an idea to Džep" (or the Action Button) saves without opening the app. Widgets: **Todos** (tick todos off from the Home Screen) and **New idea** (opens the add field).
- **Terminal**: omp's `/idea` and `/todo` (`~/.omp/agent/extensions/idea.ts`) talk to the Mac app's localhost API; ideas land under the current repo's name as their project.

The first design mockup is `design/mockup.html`.

## Layout

| Path | What |
| --- | --- |
| `lib/idea.dart` | One row of `ideas`: an idea or a todo (`kind`) |
| `lib/session.dart` | GitHub sign-in and the user's `IdeaStore` (shared) |
| `lib/store.dart` | Local JSON cache + Supabase sync (push dirty, pull since cursor, realtime) |
| `lib/controller.dart`, `popup.dart`, `main_window.dart`, `native.dart` | Mac app |
| `lib/local_api.dart` | Mac: 127.0.0.1 API for `/idea` and `/todo` |
| `lib/mobile.dart` | iPhone app |
| `macos/Runner/MainFlutterWindow.swift` | Mac panel (popup / main shapes), menu-bar icon, Carbon hotkey, launch at login |
| `ios/Runner/AddIdeaIntent.swift` | Siri / Action Button intents (Add Idea, Add Todo) |
| `ios/DzepWidget/` | WidgetKit extension (Todos, New idea) |
| `ios/Shared/DzepShared.swift` | App Group storage + `device` function client (app and widget) |
| `supabase/` | Migrations and the `device` edge function |
| `maestro/` | Simulator flows |

## Backend

Supabase project `dzep` (`tgqmhieundubwtyvsnih`, eu-central-1).

- `ideas`: ideas and todos (`kind`); a todo is open or done (`done_at`). Ids are client-generated so capture works offline; deletes are soft (`deleted_at`) so other devices learn about them; `updated_at` is set by a trigger (the sync cursor). RLS: own rows only.
- `device_tokens`: SHA-256 of per-iPhone tokens. Siri and the widget can't reach the app's session, so they call `functions/v1/device` (`{action: add | done}`) with `x-dzep-token`; the function maps the token to the user. Deployed with `--no-verify-jwt`.
- Auth: GitHub OAuth app owned by `danyzmaj-apps`; redirect `dzep://login-callback`.

```sh
supabase db push
supabase functions deploy device --no-verify-jwt
```

## Mac notes

- The window is a **non-activating `NSPanel`**, declared so in `MainMenu.xib` (`nonactivatingPanel="YES"`): since macOS 14 a background app can't take focus from the frontmost one, and AppKit only honours `.nonactivatingPanel` when a window is created with it. It's hidden at launch; `awakeFromNib` shows it once at alpha 0 so Flutter starts its engine, then Dart picks the shape.
- The popup stays mounted while hidden and reads 1/2/3/Esc through a global key handler, so a fast ⇧⌘Space-then-2 never lands before Flutter's first frame.
- Not sandboxed (global hotkey, `~/.config` file, loopback server).

## Terminal API (Mac)

On launch the Mac app listens on a random 127.0.0.1 port and writes `{port, token}` to `~/.config/dzep/cli.json` (mode 600).

```
GET   /v1/ideas?project=NAME     → {"ideas": [...]}  ideas, oldest first
GET   /v1/ideas?kind=todo        → {"ideas": [...]}  open todos, oldest first
POST  /v1/ideas                  {title, kind?, notes?, project?}
PATCH /v1/ideas/ID               {status} for an idea, {done} for a todo
Authorization: Bearer <token>
```

## Run

```sh
fvm flutter run -d macos
fvm flutter run -d ios
```

Signing: team `5SSZ6TYMF5` (Danijel Lovric) on every target; the iOS app and widget share the App Group `group.com.danyzmaj.dzep`.

## Tests

Maestro flows need a signed-in simulator:

```sh
maestro test -e TS=$(date +%H%M%S) maestro/
```
