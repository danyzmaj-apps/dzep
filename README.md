# Džep

**A pocket for dev ideas and todos.** One keystroke on the Mac, one sentence to Siri on the iPhone, synced through **your own** Supabase project. Nobody else hosts or sees your data.

*Džep* (Croatian, "pocket") is pronounced roughly "jep".

[![CI](https://github.com/danyzmaj-apps/dzep/actions/workflows/ci.yml/badge.svg)](https://github.com/danyzmaj-apps/dzep/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## What it does

- **Mac**: lives in the menu bar. ⇧⌘Space opens a Raycast-style popup, straight into the mode you used last: **Idea**, **Todo**, **Note** or **Ask** (⌘1–⌘4, or click the strip on top), field focused, ↵ saves. The menu-bar icon shows the open-todo count. The main window is a normal app window (Dock icon and menu bar while it's open, ⌘W closes it, ⌘Q quits) with Todos (finished ones fold away at the bottom), Ideas (grouped by project, with descriptions), Notes and Ask. A **Todos** widget (desktop or Notification Center; small, medium, large) lists the open todos; click a circle to tick one off.
- **Notes**: for the quick note you'd otherwise open Apple Notes for. Free text, the first line is its title; it saves as you type. Write one from the popup (⌘3; ↵ is a new line, ⌘↵ saves), the main window's Notes, the iPhone's Notes tab, "Hey Siri, add a note to Džep" or `/note` in omp.
- **Quick questions** (Mac and iPhone): **Ask** (⌘4) in the popup is a small streamed chat with the AI of your choice (any OpenAI-compatible API; DeepSeek by default). It picks up where you left off; ⌘N starts a new chat, ⇧⌘C copies the last answer (each answer also has a Copy button, and all text is selectable), ⌘O opens it in the main window. Every chat is in the main window's Ask and the iPhone's Ask tab, synced: start on one device, continue on the other. The AI key stays on your server; the apps have no key to set.
- **Images in questions**: paste a screenshot with ⌘V or attach files with 📎 (Mac), or paste / pick from Photos (iPhone); up to 4 per question. They're stored in your project's private `chat` bucket and show in the chat on every device. Needs a model that reads images, like the default `deepseek-flash`.
- **iPhone**: Todos, Ideas, Notes and Ask tabs, a + / ✎ button, swipe right to tick a todo off, swipe left to delete. Ask lists your quick-question chats (the same ones as the Mac); ✎ starts one, tap one to continue it; each answer has Copy, and the chat's copy button takes the last answer. "Hey Siri, add a todo / an idea / a note to Džep" (or the Action Button) saves without opening the app. Widgets: **Todos** (tick todos off from the Home Screen) and **New idea** (opens the add field).
- **Reminders** (todos): end a todo with `!` and a time: `call bank !15:00`, `!9`, `!3pm`, `!tomorrow 9`, `!mon 14:30`, `!30m`, `!2h`. That works in the popup, the main window's add field and the iPhone's add sheet; a chip under the field shows what it will set, and a token that doesn't read as a time stays in the title. A time already past today means tomorrow, a weekday is the next one still ahead (today only before that time), a day alone means 9:00, `today` needs a time. Change or clear it in the main window's todo detail (**Remind**: the same syntax without the `!`) or on the iPhone (long-press a todo, or **Remind me** in its detail). At that time every device that knows the reminder shows a local notification: clicking it opens the todo (Mac: selected in the main window; iPhone: its detail), **Done** ticks it off. Ticking a todo off or deleting it cancels its reminder (Undo brings it back).
- **Terminal**: omp's `/idea`, `/todo` and `/note` ([integrations/omp/idea.ts](integrations/omp/idea.ts)) talk to the Mac app's localhost API; ideas land under the current repo's name as their project.
- **Terminal from iPhone**: the iPhone's Terminal tab lists the Mac's kitty windows (omp sessions marked ✦); tap one to watch its screen live, with the newest scrollback above it (about 60 KB, a few hundred lines; scroll up for it) and type into it (typed as keystrokes, then Enter; a line break is Shift+Enter), with Esc, Tab, ↑, ↓, ⏎ and ^C keys for omp's menus. In an omp window the image button attaches a picture, pasted from the iPhone's clipboard or picked from Photos: it goes through the private Storage bucket `terminal`, and the Mac puts it on its clipboard and presses Ctrl+V, which omp attaches to the prompt (this replaces what was on the Mac's clipboard). Close a window with × on its screen or a swipe left in the list; the phone asks first, then the window and what runs in it close on the Mac. + opens a new kitty window on the Mac in one of the Mac's projects (git repos under `~/Dev`, `~/Developer`, `~/Projects`, `~/code`, `~/src`, or a typed `~/path`), starting omp unless turned off. It works while the Mac is awake (lid open) with Džep running and **Settings → Terminal from iPhone** on, which also keeps the Mac from idle sleep (`caffeinate -i`). kitty needs `allow_remote_control socket-only` and `listen_on unix:/tmp/kitty` in kitty.conf (read at startup, so restart kitty once).

## Get started

Džep has no central server. You run the backend on a free Supabase project, and every app you install connects to it. The Mac app sets it up for you in about five minutes, once.

1. **Install the Mac app.** Download `Dzep-x.y.z.dmg` from [Releases](https://github.com/danyzmaj-apps/dzep/releases/latest) and drag Džep to Applications. It updates itself.
2. **Set up your server.** On first launch Džep walks you through it: a Supabase access token, a project (it can create one), a GitHub OAuth app for sign-in, and optionally an AI key. It then creates the tables, deploys the functions and connects. Prefer a terminal? `tool/setup-backend.sh` does the same ([docs/SELF_HOSTING.md](docs/SELF_HOSTING.md)).
3. **Sign in with GitHub** on the Mac. The first account owns the server.
4. **iPhone (optional).** On the Mac: **Settings → Set up iPhone…** shows a code. On the iPhone, tap **Scan the code from your Mac**: it connects and signs in, no GitHub login on the phone. The code works once, for 10 minutes.

Requirements: macOS 13+ (the desktop widget needs 14+), iOS 17+.

## Optional extras

- **AI for quick questions.** Any OpenAI-compatible API (DeepSeek, OpenAI, OpenRouter, Groq, a local Ollama, …). The key stays on your server; see [docs/SELF_HOSTING.md](docs/SELF_HOSTING.md#ai-provider).
- **omp `/idea` and `/todo`.** Install [integrations/omp/idea.ts](integrations/omp/idea.ts) as an omp extension. Other tools can use the local [terminal API](docs/ARCHITECTURE.md#terminal-api-mac).
- **Terminal from iPhone** needs [kitty](https://sw.kovidgoyal.net/kitty/) with remote control on, and is off until you turn it on in the Mac's Settings. Anyone signed in to your account can then type into your terminals, which is one more reason the server is yours alone.

## Privacy and security

- Your data lives in your Supabase project, behind row-level security. The apps only hold its publishable key.
- The server is private. The first account to sign in owns it, and new sign-ups are refused unless you allow their email ([details](docs/SELF_HOSTING.md#sharing)).
- The AI key is a server secret and never reaches the apps.
- You can delete your account and everything in it from Settings, on the Mac or the iPhone.
- To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Development

- [docs/BUILDING.md](docs/BUILDING.md): build and run from source, use your own signing identity, run the tests.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how the pieces fit, and the platform quirks behind them.
- [docs/RELEASING.md](docs/RELEASING.md): ship a notarized DMG with a Sparkle update.
- [CONTRIBUTING.md](CONTRIBUTING.md)

## License

[MIT](LICENSE) © Danijel Lovric
