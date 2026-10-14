# Džep

[![CI](https://github.com/danyzmaj-apps/dzep/actions/workflows/ci.yml/badge.svg)](https://github.com/danyzmaj-apps/dzep/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**A pocket for ideas, todos, notes and quick AI questions.** Džep is a Mac menu-bar app with an ⇧⌘Space popup, plus iPhone and Android apps, all synced through **your own** free Supabase server. There is no Džep cloud: the Mac app sets up the server for you in a few minutes, and your phones join it by scanning a code. From the phone you can also follow and prompt the [omp](https://github.com/can1357/oh-my-pi) and [Claude Code](https://github.com/anthropics/claude-code) sessions and other terminal windows running on your Mac.

*Džep* (Croatian, "pocket") is pronounced roughly "jep".

- **Capture anywhere.** A popup on the Mac, Siri and widgets on the iPhone, widgets on Android, `/idea`, `/do` and `/note` in your coding agent.
- **Todos with reminders.** End a todo with `!15:00` or `!tomorrow` and every device reminds you; tick it off on one and it's done on all.
- **Notes.** Free text, saved as you type; on the Mac one can float in its own window.
- **Ask.** Short streamed chats with any OpenAI-compatible AI, with images. Chats sync between devices; the AI key stays on your server.
- **Terminal from the phone.** Your Mac's coding sessions as a conversation on the phone, with Live Activities (iPhone) or an ongoing notification (Android) and a push when the agent finishes or needs you.
- **Private.** Everything lives in a Supabase project you own. Notifications reach your phones encrypted with a key only they have.

## Contents

- [What you need](#what-you-need)
- [Install](#install)
- [Set up](#set-up)
- [Add your phone](#add-your-phone)
- [Use it](#use-it)
- [Privacy and security](#privacy-and-security)
- [Troubleshooting](#troubleshooting)
- [Build from source and contribute](#build-from-source-and-contribute)
- [License](#license)

## What you need

- **A Mac** with macOS 13 or newer (the desktop widget needs 14).
- **A free [Supabase](https://supabase.com) account.** It hosts your server; the free plan is plenty for one person.
- **A [GitHub](https://github.com) account**, to make a free GitHub OAuth app: it's how you sign in to your server on the Mac.
- **Optional: an API key for an OpenAI-compatible AI** (DeepSeek, OpenAI, OpenRouter, Groq, a local Ollama, …) for Ask. You can add it any time later.
- **Optional, for Terminal from the phone:** any of [kitty](https://sw.kovidgoyal.net/kitty/), [iTerm2](https://iterm2.com), [WezTerm](https://wezterm.org), [Ghostty](https://ghostty.org) or Terminal (macOS's) on the Mac, optionally [tmux](https://github.com/tmux/tmux), and [omp](https://github.com/can1357/oh-my-pi) or [Claude Code](https://github.com/anthropics/claude-code) (2.1.287 or later).
- **A phone, if you like:** an iPhone with iOS 17 or newer, or an Android phone with Android 8.0 or newer.

## Install

| Device | Where |
| --- | --- |
| **Mac** | Download `Dzep-x.y.z.dmg` from [GitHub Releases](https://github.com/danyzmaj-apps/dzep/releases/latest) and drag Džep to Applications. It's notarized by Apple and updates itself (Sparkle). |
| **iPhone** | TestFlight: *link coming soon* |
| **Android** | Google Play (open testing): *link coming soon* |

> **Coming soon.** The first notarized Mac release, the TestFlight link and the Google Play link are being prepared; they'll be added here and to the release notes when they're live. Until then, [build the apps from source](docs/BUILDING.md).

## Set up

Open Džep on the Mac. With no server yet, it starts a wizard (**Set up my server**):

1. **Supabase access token.** Click **Open Supabase access tokens**, create one (`sbp_…`) and paste it. It's used for this setup only and never saved.
2. **Project.** **Create a new project** (the region is guessed from your time zone), or **Use an existing project**. A project of its own is best: Džep won't take one that already has accounts or tables of the same names, and says which of its settings it would replace. The free plan allows two active projects; pause one if it's full.
3. **GitHub sign-in.** Click **Open GitHub: new OAuth app**. The wizard shows the **Application name** and **Authorization callback URL** to copy into GitHub's form. Register the app, generate a client secret, and paste the **Client ID** and **Client secret** back.
4. **AI (optional).** Pick DeepSeek, OpenAI, OpenRouter or **Other** (any OpenAI-compatible URL and model) and paste its key, then **Set up my server**. Or **Skip AI for now** and connect one later in **Settings → AI**.
5. **Setting up your server.** Džep creates the tables and security rules, turns on GitHub sign-in and private sign-up, and deploys its functions. It takes about a minute. If a step fails, **Retry** picks up from it.
6. **Connect and sign in** with GitHub. The first account to sign in owns the server.

Prefer a terminal? [docs/SELF_HOSTING.md](docs/SELF_HOSTING.md) does the same with a script. Already have a Džep server? **I already have one: connect it** on the first screen takes its setup link.

## Add your phone

1. On the Mac, open **Settings → Set up phone…**. It shows a QR code.
2. In the phone app, tap **Scan the code from your Mac** and point it at the screen. No camera? **Paste a code instead** takes the same code as text.
3. The phone connects to your server and signs in as you.

A code works **once** and lasts **10 minutes**, and anyone who scans it gets into your account, so show it only to your own phone. Phones never use a password or GitHub, and never set up servers: they only join one your Mac set up. A phone that signs out needs a new code.

For App Store or Google Play review, **Settings → Reviewer access → Codes…** makes a revocable code for a separate demo account on your server ([details](docs/SELF_HOSTING.md#app-store-and-play-review)).

## Use it

### The popup (Mac)

⇧⌘Space opens the popup, in the mode you used last, with its field focused. Change the shortcut in **Settings → Quick capture shortcut**. The menu-bar icon shows how many todos are open.

| Key | What it does |
| --- | --- |
| ⌘1 ⌘2 ⌘3 ⌘4 | **Idea**, **Todo**, **Note**, **Ask** (or click the strip on top) |
| ⌘5 | Open the main window |
| ↵ | Save (Idea, Todo); send the question (Ask) |
| ⌘↵ | Save and stay for the next one (Idea, Todo); save the note (Note) |
| ⇥ | Add a description, or complete an `@project` (Idea, Todo) |
| ↓ ↑ | Browse the list below the field: ideas, todos, **RECENT NOTES**, or your recent chats in Ask. In Note and Ask ↓ goes to the list from the field's last line; ↑ past the top or Esc goes back to the field |
| ↵ on a selected row | Open the idea, todo or note in the main window; in Ask, continue that chat in the popup |
| ⌘D | Tick off the selected todo |
| ⌘O | Open the app on the selected item or chat (or on Notes, or on the current chat) |
| ⌘P | Float the note in its own window: the selected one, else the one being written (Note) |
| ⌘N | New chat (Ask) |
| ⇧⌘C | Copy the last answer (Ask) |
| Esc, ⌘W | Hide the popup |

`@project` in an idea's title files it under that project.

### The main window and the note window (Mac)

The main window has **Todos** (finished ones fold away at the bottom), **Ideas** (grouped by project, with descriptions), **Notes** and **Ask**. ⌘N adds, ⌘F or / searches, ↑/↓ move, ⌫ deletes (with Undo), ⌘, opens Settings.

A note can float in a small window of its own over whatever you're doing: open it from the note's header in the main window, or with ⌘P in the popup.

### Reminders

End a todo with `!` and a time. A chip under the field shows what it will set. When it's due, your devices notify you, and **Done** ticks the todo off.

| Write | Reminds you |
| --- | --- |
| `!15:00`, `!9`, `!9.30`, `!3pm` | At that time today, or tomorrow if it's already past |
| `!tomorrow`, `!tmr`, `!fri` | That day at 9:00 |
| `!tomorrow 9`, `!mon 14:30` | That day at that time (a weekday is the next one ahead) |
| `!today 18:00` | Today at that time |
| `!30m`, `!2h`, `!1d`, `!1h30m` | That long from now |

For example `call bank !15:00`. Phones get reminders by push, so one set on the Mac arrives with the phone app closed, and one ticked off elsewhere never goes off.

### The phone apps

- **Tabs:** Todos, Ideas, Notes, Ask and Terminal. Swipe a row right to tick a todo off, left to delete.
- **Widgets:** **Todos** (tick todos off from the Home Screen) and **New idea** (opens the add field), on iPhone and Android. The Mac has a **Todos** widget too (desktop or Notification Center).
- **Siri (iPhone):** "Hey Siri, add a todo to Džep", "add an idea to Džep" or "add a note to Džep" saves without opening the app. The Action Button can do it too: Settings → Action Button → Shortcut → Džep. Android has no voice-assistant integration.
- **Account:** the avatar at the top opens Sign out and Delete account.

### Ask

A small streamed chat with the AI you connected. Paste or attach up to 4 images per question. Chats sync: start on one device, continue on another. No AI yet? Connect one from the Mac: **Settings → AI → Connect…** (or **Connect an AI…** in Ask). The key stays on your server; the apps never see it.

### Terminal from the phone

The phone's Terminal tab lists the Mac's omp and Claude Code sessions and other terminal windows.

- **A coding session** opens as a conversation laid out for the phone: your prompts, the agent's answers, tool calls as cards. Prompt it (with images), stop it, answer its questions, tool approvals and plan reviews. While omp works you can steer it or queue a prompt; Claude Code can't be steered, so a prompt waits for its run to end.
- **Any window**, a shell included, also opens as its live screen you can type into.
- **+** opens a new window in one of the Mac's projects, with a shell or your coding agent. It opens without taking the focus from what you're doing on the Mac.
- When a run ends or the agent needs you while you're away from the Mac, a push takes you to that session. A session you follow shows as a **Live Activity** on the iPhone (Lock Screen, Dynamic Island) and as an **ongoing notification** on Android.

What works depends on the terminal:

| Terminal | Sessions & screens | Colors | Keys & answers from phone | Close |
| --- | --- | --- | --- | --- |
| kitty | ✓ | ✓ | ✓ | ✓ |
| iTerm2 | ✓ | – | ✓ | ✓ |
| WezTerm | ✓ | ✓ | ✓ | ✓ |
| tmux (in any terminal) | ✓ | ✓ | ✓ | ✓ |
| Ghostty | Sessions, no screen | – | ✓ | ✓ |
| Terminal (macOS's) | ✓, whole lines only | – | – (answer asks and menus on the Mac) | ✓ |

With tmux installed (`brew install tmux`), sessions the phone starts in Terminal or Ghostty run inside tmux and get full control.

To turn it on:

1. On the Mac, turn on **Settings → Terminal from phone**. It's off by default.
2. **Settings → Terminals** lists the terminals Džep found, each Ready, Limited (and why) or Needs setup. For kitty, click **Set up…**, then restart kitty: it backs up `kitty.conf` (`.dzep-backup`) and appends `allow_remote_control socket-only` and `listen_on unix:/tmp/kitty`. For iTerm2, Terminal and Ghostty, macOS asks once whether Džep may control them; if you said no, click **Allow…** there, or turn Džep on in System Settings → Privacy & Security → Automation.
3. **New sessions open in** picks the terminal a session from your phone opens in: **Auto** (the running terminal you used last, else the first that works) or a specific one.
4. In **Settings → Coding agent**, pick omp or Claude Code: it's what a new session from your phone starts. The row under it, **Džep in …**, installs or updates Džep's integration for that agent. Restart running sessions afterwards.

The integration also adds three commands to your agent, saved through the Mac app and filed under the current repo's name:

| Command | Saves |
| --- | --- |
| `/idea <text>` | An idea (`/idea list` lists this project's) |
| `/do <text>` | A todo, reminders included: `/do call bank !15:00` |
| `/note <text>` | A note |

To install the integration by hand instead:

- **omp:** copy [idea.ts](apps/dzep-macos-app/integrations/omp/idea.ts) and [live.ts](apps/dzep-macos-app/integrations/omp/live.ts) to `~/.omp/agent/extensions/`.
- **Claude Code** (2.1.287 or later, with mods on): from a checkout of this repo, `claude plugin marketplace add apps/dzep-macos-app/integrations/claude`, then `claude plugin install dzep@dzep`. If Settings says mods are off, run `claude /login`, start `claude` once, then restart your sessions.

Other tools can use the same [local API](docs/ARCHITECTURE.md#terminal-api-mac).

## Privacy and security

- **Your data, your server.** Everything you write lives in your Supabase project, behind row-level security. The apps hold only its publishable key. The first account owns the server, and anyone else's sign-up is refused unless you allow their email ([Sharing](docs/SELF_HOSTING.md#sharing)).
- **AI key.** A secret on your server; it never reaches the apps. Questions go from your server to the AI provider you chose.
- **What the publisher's relay sees.** Only the app's publisher can reach Apple's and Google's push services for Džep, so your server sends notifications through the publisher's relay. Each phone makes its own AES-256 key and gives it only to your server, which encrypts every notification with it. The relay sees the phone's push token, the kind of notification (reminder, terminal or session state), a collapse id (a todo id or a session key) and ciphertext. It never sees titles, todo text or terminal output, and it stores nothing. One exception: iPhone Live Activity updates can't be encrypted, so for those it sees the session's state (working, needs you, finished) and since when. On Android those are encrypted too.
- **Terminal from the phone** lets anyone signed in to your account type into your terminals. It's off by default and runs over a Realtime channel only your account can join; nothing it carries is stored.
- **Delete everything** from Mac Settings → **Delete account**, or the phone's account menu.
- Report vulnerabilities privately: [SECURITY.md](SECURITY.md). The full privacy policy: [docs/PRIVACY.md](docs/PRIVACY.md).

## Troubleshooting

Most problems are in the [troubleshooting table](docs/SELF_HOSTING.md#troubleshooting): GitHub sign-in, a phone code that doesn't work, a server older than the app, Ask without an AI key. Still stuck? [Open an issue](https://github.com/danyzmaj-apps/dzep/issues/new/choose).

## Build from source and contribute

- [docs/BUILDING.md](docs/BUILDING.md): build the Mac, iPhone and Android apps, with your own signing identity.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how the pieces fit, and why some of them look odd.
- [docs/SELF_HOSTING.md](docs/SELF_HOSTING.md): the server, by script, and updating it.
- [docs/RELEASING.md](docs/RELEASING.md): how releases are made.
- [CONTRIBUTING.md](CONTRIBUTING.md): issues and pull requests are welcome.

The repo is a Dart pub workspace: the Mac app and the backend it deploys in [`apps/dzep-macos-app/`](apps/dzep-macos-app/), the iPhone and Android app in [`apps/dzep-mobile/`](apps/dzep-mobile/), shared code in [`packages/dzep_core/`](packages/dzep_core/).

**Forking?** The Apple team, bundle ids, Android package, Sparkle update feed and push relay default to the publisher's. Builds for yourself override the team and ids in `config/Local.xcconfig` ([BUILDING.md](docs/BUILDING.md#your-signing-identity)). A fork that ships its own apps also sets its own Android package ([BUILDING.md](docs/BUILDING.md#android)), Sparkle key and feed ([RELEASING.md](docs/RELEASING.md#one-time-setup-maintainers-mac)) and push relay ([SELF_HOSTING.md](docs/SELF_HOSTING.md#your-own-app-id-and-relay)).

## License

[MIT](LICENSE) © Danijel Lovric
