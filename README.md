# Džep

A personal pocket for dev ideas and work todos: one keystroke on the Mac, one sentence to Siri on the iPhone, synced through Supabase.

- **Mac**: lives in the menu bar. ⇧⌘Space opens a Raycast-style popup with a chooser: **1** idea, **2** todo, **3** open the app; the field is focused right away and ↵ saves. The menu-bar icon shows the open-todo count. The main window is a normal app window (Dock icon and menu bar while it's open, ⌘W closes it, ⌘Q quits) with Todos (open / done) and Ideas (grouped by project, with descriptions); every item shows when it was added.
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
| `macos/Runner/MainFlutterWindow.swift`, `AppDelegate.swift` | Popup panel + main window on one multi-view engine, menu-bar icon, Carbon hotkey, activation policy, launch at login |
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

- **Two windows, one Flutter app.** The engine runs in multi-view mode (`enableMultiView`, the private switch Flutter's own experimental multi-window API uses; it must be flipped before any view attaches, and views attach only after the engine runs). View 1 is the popup, view 2 the main window; `lib/main.dart` puts a `View` + `MaterialApp` on each and both read one `AppController`.
- The **popup** is an `NSPanel` created with `.nonactivatingPanel` (only honoured at creation): since macOS 14 a background app can't take focus from the frontmost one, and this panel takes the keyboard without activating Džep. It's a fixed transparent 720×660 and never resizes; Flutter animates the panel inside it (after any resize Flutter blocks until it has drawn the new size, and Impeller crashes on rapid ones). Esc is Dart's (`cancelOperation` is a no-op).
- The **main window** is a regular `NSWindow`. Showing it switches the app to `.regular` (Dock icon, menu bar) and activates it; closing it (⌘W, red button) hides it and switches back to `.accessory`. `LSUIElement` is gone: `AppDelegate` sets `.accessory` at launch instead. The Dock icon reopens the window.
- Flutter's engine reads "is the app visible" from NSApplication's occlusion state, which a non-activating panel doesn't update; frames would stop. Each window sends `AppLifecycleState.resumed` on `flutter/lifecycle` when it appears.
- Hiding the popup on purpose doesn't report a "blur" to Dart (a late blur would close a popup the next hotkey just opened). The popup stays mounted while hidden and reads 1/2/3/Esc through a global key handler, so a fast ⇧⌘Space-then-2 never lands before Flutter's first frame.
- Not sandboxed (global hotkey, `~/.config` file, loopback server).

## Terminal API (Mac)

On launch the Mac app listens on a random 127.0.0.1 port and writes `{port, token}` to `~/.config/dzep/cli.json` (mode 600).

```
GET   /v1/ideas?project=NAME     → {"ideas": [...]}  ideas, oldest first
GET   /v1/ideas?kind=todo        → {"ideas": [...]}  open todos, oldest first
POST  /v1/ideas                  {title, kind?, notes?, project?}
PATCH /v1/ideas/ID               {done} (todos only)
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
