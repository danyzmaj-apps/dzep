# Džep

A personal pocket for dev ideas and work todos: one keystroke on the Mac, one sentence to Siri on the iPhone, synced through Supabase.

- **Mac**: lives in the menu bar. ⇧⌘Space opens a Raycast-style popup with a chooser: **1** idea, **2** todo, **3** ask, **4** open the app; the field is focused right away and ↵ saves. The menu-bar icon shows the open-todo count. The main window is a normal app window (Dock icon and menu bar while it's open, ⌘W closes it, ⌘Q quits) with Todos (open / done), Quick questions and Ideas (grouped by project, with descriptions); every item shows when it was added. A **Todos** widget (desktop or Notification Center; small, medium, large) lists the open todos; click a circle to tick one off.
- **Quick questions** (Mac and iPhone): **3** in the popup is a small chat with DeepSeek (`deepseek-flash`, thinking off, streamed). It picks up where you left off; ⌘N starts a new chat, ⇧⌘C copies the last answer (each answer also has a Copy button, and all text is selectable), ⌘O opens it in the main window. Every chat is in the main window's Quick questions and the iPhone's Ask tab, synced: start on one device, continue on the other. Questions go through the `ask` edge function, which holds the DeepSeek key, so the apps have no key to set.
- **iPhone**: Todos, Ideas and Ask tabs, a + button, swipe right to tick a todo off. Ask lists your quick-question chats (the same ones as the Mac); ✎ starts one, tap one to continue it, swipe left to delete; each answer has Copy, and the chat's copy button takes the last answer. "Hey Siri, add a todo / an idea to Džep" (or the Action Button) saves without opening the app. Widgets: **Todos** (tick todos off from the Home Screen) and **New idea** (opens the add field).
- **Reminders** (todos): end a todo with `!` and a time: `call bank !15:00`, `!9`, `!3pm`, `!tomorrow 9`, `!mon 14:30`, `!30m`, `!2h`. That works in the popup, the main window's add field and the iPhone's add sheet; a chip under the field shows what it will set, and a token that doesn't read as a time stays in the title. A time already past today means tomorrow, a weekday is the next one still ahead (today only before that time), a day alone means 9:00, `today` needs a time. Change or clear it in the main window's todo detail (**Remind**: the same syntax without the `!`) or on the iPhone (long-press a todo, or **Remind me** in its detail). At that time every device that knows the reminder shows a local notification: clicking it opens the todo (Mac: selected in the main window; iPhone: its detail), **Done** ticks it off. Ticking a todo off or deleting it cancels its reminder (Undo brings it back).
- **Terminal**: omp's `/idea` and `/todo` (`~/.omp/agent/extensions/idea.ts`) talk to the Mac app's localhost API; ideas land under the current repo's name as their project.
- **Terminal from iPhone**: the iPhone's Terminal tab lists the Mac's kitty windows (omp sessions marked ✦); tap one to watch its screen live and type into it (typed as keystrokes, then Enter; a line break is Shift+Enter), with Esc, Tab, ↑, ↓, ⏎ and ^C keys for omp's menus. Close a window with × on its screen or a swipe left in the list; the phone asks first, then the window and what runs in it close on the Mac. + opens a new kitty window on the Mac in one of the Mac's projects (git repos under `~/Dev`, `~/Developer`, `~/Projects`, `~/code`, `~/src`, or a typed `~/path`), starting omp unless turned off. It works while the Mac is awake (lid open) with Džep running and **Settings → Terminal from iPhone** on, which also keeps the Mac from idle sleep (`caffeinate -i`). kitty needs `allow_remote_control socket-only` and `listen_on unix:/tmp/kitty` in kitty.conf (read at startup, so restart kitty once).

The first design mockup is `design/mockup.html`.

## Layout

| Path | What |
| --- | --- |
| `lib/idea.dart` | One row of `ideas`: an idea or a todo (`kind`) |
| `lib/session.dart` | GitHub sign-in and the user's `IdeaStore` (shared) |
| `lib/remind.dart` | Reminders: the `!` parser, how a time reads, which todos should have a notification pending (pure Dart, `test/remind_test.dart`) |
| `lib/store.dart` | Local JSON cache + Supabase sync (push dirty, pull since cursor, realtime) |
| `lib/controller.dart`, `popup.dart`, `main_window.dart`, `native.dart` | Mac app |
| `lib/chat.dart`, `chat_view.dart` | Quick questions: `ChatStore` (synced chats, streaming from `ask`) and the transcript/list/thread widgets (Mac and iPhone) |
| `lib/kitty.dart` | Mac: kitty's remote control through `kitten @` (windows, screen text, typing, keys, new windows) |
| `lib/terminal.dart`, `terminal_view.dart` | Terminal from iPhone: the protocol, `TerminalBridge` (Mac), `TerminalRemote` and its screens (iPhone) |
| `lib/local_api.dart` | Mac: 127.0.0.1 API for `/idea` and `/todo` |
| `lib/mobile.dart` | iPhone app |
| `macos/Runner/MainFlutterWindow.swift`, `AppDelegate.swift` | Popup panel + main window on one multi-view engine, menu-bar icon, Carbon hotkey, activation policy, launch at login, reminder notifications |
| `ios/Runner/AppDelegate.swift` | The iPhone half of `native.dart`: App Group, reminder notifications |
| `ios/Runner/AddIdeaIntent.swift` | Siri / Action Button intents (Add Idea, Add Todo) |
| `ios/DzepWidget/` | WidgetKit extension (Todos, New idea) |
| `macos/DzepWidget/` | Mac WidgetKit extension (Todos), sandboxed; its ticks go through the running app |
| `ios/Shared/DzepShared.swift` | App Group storage + `device` function client (app and widget; the Mac's app and widget compile it too) |
| `supabase/` | Migrations and the `device` edge function |
| `maestro/` | Simulator flows |

## Backend

Supabase project `dzep` (`tgqmhieundubwtyvsnih`, eu-central-1).

- `ideas`: ideas and todos (`kind`); a todo is open or done (`done_at`) and may have a reminder (`remind_at`, null for none; clients that predate the column don't send it, so their upserts leave it alone). Ids are client-generated so capture works offline; deletes are soft (`deleted_at`) so other devices learn about them; `updated_at` is set by a trigger (the sync cursor). RLS: own rows only.
- `device_tokens`: SHA-256 of per-iPhone tokens. Siri and the widget can't reach the app's session, so they call `functions/v1/device` (`{action: add | done}`) with `x-dzep-token`; the function maps the token to the user. Deployed with `--no-verify-jwt`.
- `chats` + `chat_messages`: quick-question chats. The app picks a chat's id; only the `ask` function writes messages. A new message moves its chat's `updated_at` (trigger), so devices pull changed chats by that cursor (and realtime on `chats`) and refetch their messages. Deletes are soft (`chats.deleted_at`). RLS: own rows only, and messages only into one's own chats.
- `functions/v1/ask` (`{chat_id, question}`, the user's token): creates the chat if new, saves the question, streams DeepSeek's answer back as server-sent events (`{delta}` … `{done}` or `{error}`) and saves it, even if the app goes away mid-answer (`EdgeRuntime.waitUntil`). The DeepSeek key is the secret `DEEPSEEK_API_KEY`. Deployed with `--no-verify-jwt`: the token is checked in the function with `auth.getUser`.
- Terminal from iPhone: private Realtime broadcast on `terminal:<user id>`, nothing stored. RLS on `realtime.messages` lets only that user join, to receive or to send (a public channel of the same name is a separate room the apps never join). While its Terminal screens are open the iPhone says `hello` every 4 s; the Mac answers each with `state` (windows, projects) and, while some phone has said hello in the last 12 s, polls kitty every second and sends a watched window's `screen` when it changes. `run` (`send`, `key`, `launch`, `close`) is answered with `ran`. The iPhone calls the Mac offline after 10 s without word. Window keys are `<socket>/<window id>`; keys are a fixed list, and nothing the phone sends reaches a shell except as typed text.
- Auth: GitHub OAuth app owned by `danyzmaj-apps`; redirect `dzep://login-callback`.

```sh
supabase db push
supabase functions deploy device --no-verify-jwt
supabase functions deploy ask --no-verify-jwt
supabase secrets set DEEPSEEK_API_KEY=…
```

## Mac notes

- **Two windows, one Flutter app.** The engine runs in multi-view mode (`enableMultiView`, the private switch Flutter's own experimental multi-window API uses; it must be flipped before any view attaches, and views attach only after the engine runs). View 1 is the popup, view 2 the main window; `lib/main.dart` puts a `View` + `MaterialApp` on each and both read one `AppController`.
- The **popup** is an `NSPanel` created with `.nonactivatingPanel` (only honoured at creation): since macOS 14 a background app can't take focus from the frontmost one, and this panel takes the keyboard without activating Džep. It's a fixed transparent 720×660 and never resizes; Flutter animates the panel inside it (after any resize Flutter blocks until it has drawn the new size, and Impeller crashes on rapid ones). Esc is Dart's (`cancelOperation` is a no-op).
- The **main window** is a regular `NSWindow`. Showing it switches the app to `.regular` (Dock icon, menu bar) and activates it; closing it (⌘W, red button) hides it and switches back to `.accessory`. `LSUIElement` is gone: `AppDelegate` sets `.accessory` at launch instead. The Dock icon reopens the window.
- Flutter's engine reads "is the app visible" from NSApplication's occlusion state, which a non-activating panel doesn't update; frames would stop. Each window sends `AppLifecycleState.resumed` on `flutter/lifecycle` when it appears.
- Hiding the popup on purpose doesn't report a "blur" to Dart (a late blur would close a popup the next hotkey just opened). The popup stays mounted while hidden and reads 1/2/3/Esc through a global key handler, so a fast ⇧⌘Space-then-2 never lands before Flutter's first frame.
- Not sandboxed (global hotkey, `~/.config` file, loopback server).
- **Desktop widget** (`macos/DzepWidget/`, macOS 14+ for its tick buttons; the app still runs on 13): a WidgetKit extension in `Dzep.app/Contents/PlugIns`. Extensions must be sandboxed, so it is, with the App Group and no network. The app writes the open todos to the App Group whenever they change (`setSharedTodos`; removed on sign-out, which the widget shows as "sign in") and reloads the widget. A tick never calls the server: the widget hides the todo, queues `{action: done, id}` (the iPhone's offline queue) and posts the Darwin notification `group.com.danyzmaj.dzep.queued`; the menu-bar app takes the queue (`Session.drainPending`) and ticks the todo in its store, which syncs. If Džep isn't running, that happens on its next launch.
- **App Group** `group.com.danyzmaj.dzep` (the iPhone's id) on both Mac targets; the app isn't sandboxed but needs the entitlement to share the container. iOS-style ids work on the Mac when a provisioning profile authorises them (macOS 15+ otherwise asks before opening the container), so both targets set `REGISTER_APP_GROUPS = YES` and automatic signing puts the group in their Mac Team profiles. `flutter run` doesn't fetch profiles: on a new Mac, or once they expire (a year), run `xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -allowProvisioningUpdates build` once.
- `macos/DzepWidget/DzepWidget.xcconfig` clears `OTHER_LDFLAGS`: the project-level configs carry Runner's CocoaPods settings, which would link Flutter's plugin frameworks into the extension.
- With several `Dzep.app` builds on disk, `pluginkit -m -v -i com.danyzmaj.dzep.DzepWidget` shows which copy's widget macOS registered.

## Reminders

- Each device schedules its own local notifications (`UNUserNotificationCenter`; identifier = todo id, body = title). Which ones is Dart's call (`pendingReminders`: open todos whose reminder is still ahead, soonest first, at most 64, the iPhone's limit), redone on every store change (`Session`); the Swift side only replaces the pending set (`setReminders`). The first non-empty set asks for permission; if it was denied, enable Džep in System Settings / Settings → Notifications.
- Native code rather than `flutter_local_notifications`: the same few lines of `UNUserNotificationCenter` on both platforms, no timezone packages, and the actions need the app's own paths anyway: **Done** goes through the desktop widget's queue on the Mac (applied once the store is open, even when the click launched Džep) and through the `device` function on the iPhone (like the Todos widget, so it works with the app closed; queued if offline). A click on the Mac sends `openTodo {id}` → `AppController.openMain(select:)`; a tap on the iPhone is kept until Dart asks (`takeTappedTodo`), since the tap that launches the app arrives before Dart listens.
- **iPhone caveat:** the phone schedules what its store knows, which is current only while the app runs (launch, coming back to the foreground, live updates while open). A reminder set on the Mac reaches the iPhone the next time Džep is opened there, and a todo ticked off elsewhere can still go off on the phone until then. There's no server push and no background refresh: the sync is Dart, which doesn't run while the app is in the background, and a second headless engine would race the app for the session's refresh token and the cache file.

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

Signing: team `5SSZ6TYMF5` (Danijel Lovric) on every target; on both platforms the app and its widget share the App Group `group.com.danyzmaj.dzep`.

## Tests

Unit tests (the reminder parser and which reminders are pending):

```sh
fvm flutter test
```

Maestro flows need a signed-in simulator (the test account `maestro@dzep.test`); `ask.yaml` also needs the network, since it asks a real question through the `ask` function and deletes its chat at the end:

```sh
maestro test -e TS=$(date +%H%M%S) maestro/
```
