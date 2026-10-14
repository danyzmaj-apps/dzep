# Džep

**A pocket for ideas, todos, notes and quick AI questions.** A Mac menu-bar app with an ⇧⌘Space popup, plus iPhone and Android apps, all synced through **your own** free Supabase server. From the phone you can also follow and prompt [omp](https://github.com/can1357/oh-my-pi) and [Claude Code](https://github.com/anthropics/claude-code) sessions and other [kitty](https://sw.kovidgoyal.net/kitty/) windows running on your Mac.

*Džep* (Croatian, "pocket") is pronounced roughly "jep".

[![CI](https://github.com/danyzmaj-apps/dzep/actions/workflows/ci.yml/badge.svg)](https://github.com/danyzmaj-apps/dzep/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

There is no Džep cloud. Your data lives in a Supabase project you own; the Mac app creates it for you in a few minutes, and the phones pair with it by scanning a code.

## Features

### Mac

- **Popup.** ⇧⌘Space opens a Raycast-style popup, straight into the mode you used last: **Idea**, **Todo**, **Note** or **Ask** (⌘1–⌘4, or click the strip on top; ⌘5 opens the app), field focused, ↵ saves. In Idea and Todo, ⌘↵ saves and stays for the next one, ⇥ adds a description (or completes an `@project`), ↓ browses the list below, ⌘D ticks off the selected todo and ⌘O opens the app on the selected item. Esc or ⌘W hides it. The menu-bar icon shows the open-todo count.
- **Main window.** Todos (finished ones fold away at the bottom), Ideas (grouped by project, with descriptions), Notes and Ask. ⌘N new item, ⌘F or / search, ↑/↓ move, ⌫ deletes (with Undo), ⌘, Settings.
- **Note window.** A note can float in a small window of its own over whatever you're doing: from the note's header in the main window, or ⌘P in the popup's Note mode.
- **Widget.** A **Todos** widget (desktop or Notification Center) lists open todos; click a circle to tick one off.
- **Terminal.** `/idea`, `/do` (a todo) and `/note` in omp ([integrations/omp/idea.ts](apps/dzep-macos-app/integrations/omp/idea.ts)) and in Claude Code (Džep's plugin, [integrations/claude](apps/dzep-macos-app/integrations/claude)) save through the Mac app's localhost API, filed under the current repo's name. **Settings → Coding agent** picks which agent a session started from your phone runs, and the row under it installs or updates Džep's integration for it. Other tools can use the same [terminal API](docs/ARCHITECTURE.md#terminal-api-mac).
- Updates itself (Sparkle). macOS 13+, the widget needs 14+.

### iPhone

- Todos, Ideas, Notes and Ask tabs; swipe right to tick a todo off, left to delete.
- "Hey Siri, add a todo / an idea / a note to Džep" (or the Action Button) saves without opening the app.
- Widgets: **Todos** (tick todos off from the Home Screen) and **New idea** (opens the add field).
- **Terminal** tab (below), with omp and Claude Code sessions as **Live Activities** on the Lock Screen and in the Dynamic Island.
- Push notifications for reminders and for coding sessions that need you.
- iOS 17+.

### Android

The same as the iPhone app, except Siri: there is no voice-assistant integration on Android.

- Todos, Ideas, Notes, Ask and Terminal tabs, the same gestures.
- Home-screen widgets: **Todos** (tick todos off) and **New idea**.
- A followed omp or Claude Code session shows as an **ongoing notification** (working, needs you, finished), the Android counterpart of a Live Activity.
- Push notifications for reminders (with a **Done** action) and for coding sessions, through Firebase Cloud Messaging, end-to-end encrypted like on the iPhone.
- Android 8.0 (API 26) or newer.

### Everywhere

- **Notes.** Free text, the first line is the title, saved as you type.
- **Quick questions.** A small streamed chat with any OpenAI-compatible API (DeepSeek by default, or OpenAI, OpenRouter, Groq, a local Ollama, …). Chats sync: start on one device, continue on another. Paste or attach up to 4 images per question. The AI key stays on your server; the apps never have one. No AI yet? Connect one any time from the Mac: **Settings → AI**.
- **Reminders.** End a todo with `!` and a time: `call bank !15:00`, `!9`, `!3pm`, `!tomorrow 9`, `!mon 14:30`, `!30m`, `!2h`. A chip under the field shows what it will set. At that time your devices notify you; **Done** ticks the todo off. Phones get reminders by push, so one set on the Mac arrives with the phone app closed, and one ticked off elsewhere never goes off.
- **Terminal from the phone.** The Terminal tab lists the Mac's omp and Claude Code sessions and other kitty windows. A session opens as a conversation laid out for the phone: your prompts, the agent's answers as Markdown, tool calls as cards. Prompt it (with images), stop it, answer its questions, tool approvals and plan reviews, page back through older messages. While omp works you can steer it or queue a prompt; Claude Code can't be steered, so a prompt sent while it works waits for the run to end. Any window, a shell included, also opens as its live screen you can type into. **+** opens a new kitty window in one of the Mac's projects, with a shell or the agent chosen in **Settings → Coding agent**. When a run ends or the agent needs you while you're away from the Mac, a push takes you to that session. Off until you turn on **Settings → Terminal from phone** on the Mac.

## Get it

### Mac

Download `Dzep-x.y.z.dmg` from [GitHub Releases](https://github.com/danyzmaj-apps/dzep/releases/latest) and drag Džep to Applications. It is notarized by Apple and updates itself. The first notarized release is being prepared; until it's there, [build it from source](docs/BUILDING.md#mac).

### iPhone

Coming soon: TestFlight, then the App Store. The links will be added here and to the release notes when they are live. Until then you can [build it from source](docs/BUILDING.md#iphone).

### Android

Coming soon: Google Play. The link will be added here and to the release notes when it is live. Until then you can [build it from source](docs/BUILDING.md#android).

## Set up

1. **Install the Mac app** and open it.
2. **Let the wizard set up your server.** It asks for a Supabase access token, picks or creates a project, walks you through a GitHub OAuth app for sign-in, and optionally takes an AI key (skip it and connect one later in **Settings → AI**). Then it creates the tables, deploys the functions and connects. Sign in with GitHub; the first account owns the server. Prefer a terminal? See [docs/SELF_HOSTING.md](docs/SELF_HOSTING.md).
3. **Pair your phone.** On the Mac, **Settings → Set up phone…** shows a QR code. In the phone app, tap **Scan the code from your Mac** (or **Paste a code instead** with the same code as text). The phone connects and signs in as you. The code works once, for 10 minutes.

Phones sign in only with a code from your Mac, never with GitHub, and they don't set up servers: they only pair with one a Mac has set up. For App Store or Play review, **Settings → Reviewer access** makes a revocable code for a separate demo account on your server ([Self-hosting](docs/SELF_HOSTING.md#app-store-and-play-review)).

**Terminal from the phone** also needs kitty with remote control (`allow_remote_control socket-only` and `listen_on unix:/tmp/kitty` in kitty.conf).

**`/idea`, `/do`, `/note` and sessions on the phone** need Džep's integration in your coding agent. On the Mac, pick the agent in **Settings → Coding agent** and click **Install** (or **Update**) on the row under it, then restart its running sessions. To do it by hand:

- **omp**: copy [integrations/omp/idea.ts](apps/dzep-macos-app/integrations/omp/idea.ts) and [live.ts](apps/dzep-macos-app/integrations/omp/live.ts) to `~/.omp/agent/extensions/`.
- **Claude Code** 2.1.287 or later, with mods on: from a checkout of this repo, `claude plugin marketplace add apps/dzep-macos-app/integrations/claude`, then `claude plugin install dzep@dzep`. Claude Code keeps mods off until it has fetched its settings while you're logged in: if Settings says mods are off, run `claude /login`, start `claude` once, then restart your sessions.

## Privacy and security

- **Your server.** Everything you write lives in your Supabase project, behind row-level security. The apps hold only its publishable key. The first account owns the server and new sign-ups are refused unless you allow their email ([Sharing](docs/SELF_HOSTING.md#sharing)).
- **AI key.** A secret on your server; it never reaches the apps. Questions go from your server to the AI provider you chose.
- **Push.** Only the app's publisher can talk to Apple's (APNs) and Google's (FCM) push services for Džep, so your server sends notifications through the publisher's relay. Each phone makes its own AES-256 key and gives it only to your server, which encrypts every notification with it. The relay sees the device's push token, the kind of notification (reminder, terminal or session state), a collapse id (a todo id or a coding session's key) and ciphertext; it never sees titles, todo text or terminal output, and it stores nothing. One exception: iPhone Live Activity updates can't be encrypted (iOS shows them without running the app's code), so for those the relay sees the session's state (working, needs you, finished) and since when, nothing else. On Android those updates are encrypted too.
- **Terminal from the phone** lets anyone signed in to your account type into your terminals. It is off by default and runs over a Realtime channel only your account can join; nothing it carries is stored.
- Delete your account and everything in it from Settings, on any device.
- Report vulnerabilities privately: [SECURITY.md](SECURITY.md).
- The full privacy policy (also the one the app stores link to): [docs/PRIVACY.md](docs/PRIVACY.md).

## Repository

A Dart pub workspace (root `pubspec.yaml`) with three members:

| Path | What |
| --- | --- |
| [`apps/dzep-macos-app/`](apps/dzep-macos-app/) | The Mac app, and the backend it bundles and deploys: `supabase/` (migrations, edge functions), `tool/` (setup, relay and release scripts), `integrations/` (omp's extensions, the Claude Code plugin) |
| [`apps/dzep-mobile/`](apps/dzep-mobile/) | The iPhone and Android app (`ios/`, `android/`) |
| [`packages/dzep_core/`](packages/dzep_core/) | Shared Dart: sync store, session, chat, reminders, terminal protocol, UI |
| [`config/`](config/) | Apple team, bundle id and App Group for every Xcode target |
| [`docs/`](docs/) | Architecture, building, releasing, self-hosting |

## Building from source

See [docs/BUILDING.md](docs/BUILDING.md). [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the pieces fit, [docs/RELEASING.md](docs/RELEASING.md) how releases are made.

## Contributing

Issues and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © Danijel Lovric
