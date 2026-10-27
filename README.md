# Džep

**Your Mac's coding sessions on your phone: omp and Claude Code as a conversation you can prompt, steer and answer from anywhere. Plus a pocket for todos, ideas, notes and quick AI questions, on your own server.**

[![Latest release](https://img.shields.io/github/v/release/danyzmaj-apps/dzep?label=release)](https://github.com/danyzmaj-apps/dzep/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platforms: macOS, iOS, Android](https://img.shields.io/badge/platforms-macOS%20%7C%20iOS%20%7C%20Android-lightgrey.svg)](#install)

<table>
  <tr>
    <td width="33%"><img src="docs/images/phone-terminal.png" alt="iPhone: the Terminal tab, the Mac's coding sessions grouped by project, and its other windows" width="260"></td>
    <td width="33%"><img src="docs/images/phone-session.png" alt="Phone: a coding session as a conversation, with tool-call cards" width="260"></td>
    <td width="33%"><img src="docs/images/phone-terminal-android.png" alt="Android: the Terminal tab in Material 3" width="260"></td>
  </tr>
  <tr>
    <td align="center"><sub>iPhone: your Mac's sessions, by project</sub></td>
    <td align="center"><sub>A coding session as a conversation</sub></td>
    <td align="center"><sub>Android: the same, in Material 3</sub></td>
  </tr>
</table>

Džep is a Mac menu-bar app plus iPhone and Android apps. Leave a coding agent working on your Mac, walk away, and keep driving it from your phone: a push when it finishes or needs you, its questions and approvals answered with a tap. Everything syncs through a free [Supabase](https://supabase.com) project that **you** own: there is no Džep cloud. *Džep* is Croatian for "pocket", said roughly "jep".

## What it does

- **Terminal from the phone:** your Mac's [omp](https://github.com/can1357/oh-my-pi) and [Claude Code](https://github.com/anthropics/claude-code) sessions as conversations, grouped by project. Prompt them (with images), steer or stop a run, answer questions, approvals and plan reviews, and start a new session in any project. Any other terminal window is a live screen you can type into.
- **Never miss a finished run:** a push when the agent finishes or needs you, a Live Activity on the iPhone and an ongoing notification on Android for the session you follow.
- **Capture anywhere:** `/idea`, `/do` and `/note` in your coding agent, the Mac's ⇧⌘Space popup, or phone widgets.
- **Todos with reminders, notes and Ask:** `call bank !15:00` reminds every device; free-text notes; short streamed chats with any OpenAI-compatible AI.
- **Phone apps your way:** **Terminal**, **Pocket** (todos, ideas and notes in one list) and **Ask**; hide or reorder tabs in **Account → Tabs**. iOS's look on iPhone, Material 3 on Android.
- **Private by design:** your data stays in your Supabase project, and pushes reach your phones encrypted.

## Install

| Device | Get it |
| --- | --- |
| **Mac** (macOS 13+) | `Dzep-x.y.z.dmg` from [GitHub Releases](https://github.com/danyzmaj-apps/dzep/releases/latest). Notarized; updates itself. |
| **iPhone** (iOS 17+) | TestFlight: *coming soon* |
| **Android** (8.0+) | Google Play: *coming soon* |

Until the phone links are up, you can [build the phone app from source](docs/BUILDING.md).

## Get started

1. **Set up your server.** Open Džep on the Mac and click **Set up my server**. The wizard takes about five minutes and needs a free [Supabase](https://supabase.com) account (it hosts your server) and a [GitHub](https://github.com) account (you sign in with it). An AI key for Ask is optional. Would you rather use a script? See [SELF_HOSTING.md](docs/SELF_HOSTING.md).
2. **Add your phone.** On the Mac, open **Settings → Set up phone…**, then tap **Scan the code from your Mac** in the phone app. The code works once, for 10 minutes.
3. **Turn on Terminal from phone.** On the Mac, **Settings → Terminal from phone**, then pick your agent in **Settings → Coding agent** and install its integration from the row under it ([step by step](docs/USING.md#turning-it-on)). Your sessions show up in the phone's Terminal tab, where the app opens.

<table>
  <tr>
    <td width="33%"><img src="docs/images/wizard-token.png" alt="Setup wizard, step 1: paste a Supabase access token" width="260"></td>
    <td width="33%"><img src="docs/images/wizard-github.png" alt="Setup wizard, step 3: the GitHub OAuth app's values with copy buttons, and fields for its Client ID and secret" width="260"></td>
    <td width="33%"><img src="docs/images/wizard-ready.png" alt="Setup wizard, finished: every step ticked, Connect and sign in" width="260"></td>
  </tr>
  <tr>
    <td align="center"><sub>Paste a Supabase token (used once, never saved)</sub></td>
    <td align="center"><sub>Register a GitHub sign-in app: copy each value</sub></td>
    <td align="center"><sub>Done: connect and sign in with GitHub</sub></td>
  </tr>
</table>

## Terminal from the phone

The phone's Terminal tab lists the Mac's omp and Claude Code sessions under a heading for each project, the one needing you first. A session opens as a conversation: prompt it (with images), stop a run, answer questions, approvals and plan reviews; while omp works you can steer it or queue the next prompt. Any other terminal window shows as a live screen you can type into, and **+** opens a new session in one of your projects without taking the Mac's focus.

What works depends on the terminal:

| Terminal | Sessions & screens | Colors | Keys & answers from phone | Close |
| --- | --- | --- | --- | --- |
| kitty | ✓ | ✓ | ✓ | ✓ |
| iTerm2 | ✓ | – | ✓ | ✓ |
| WezTerm | ✓ | ✓ | ✓ | ✓ |
| tmux (in any terminal) | ✓ | ✓ | ✓ | ✓ |
| Ghostty | Sessions, no screen | – | Keys; – (answer on the Mac) | ✓ |
| Terminal (macOS's) | ✓, whole lines only | – | – (answer on the Mac) | ✓ |

With tmux installed (`brew install tmux`), sessions the phone starts in Terminal or Ghostty run inside tmux and get full control. Terminal from phone is off by default; **Settings → Terminals** and **Settings → Coding agent** set up the rest ([step by step](docs/USING.md#terminal-from-the-phone)). Claude Code needs version 2.1.287 or later.

> [!NOTE]
> **Your Mac has to be awake, with Džep running and Terminal from phone on.** The sessions live on the Mac; the phone only shows and drives them. While Terminal from phone is on, Džep keeps an idle Mac from sleeping, but a closed lid (without an external display) or a shut-down Mac still ends it: the phone then says the Mac isn't answering. Pushes for a run that ends while you're away need the Mac awake too. Your ideas, todos, notes, reminders and Ask don't need the Mac; only adding a phone does.

## Capture: todos, ideas, notes and Ask

Press ⇧⌘Space anywhere on the Mac. ⌘1–⌘4 switch between **Idea**, **Todo**, **Note** and **Ask**, in the strip's order (**Settings → Popup tabs** hides or reorders them). In your coding agent, `/idea`, `/do` and `/note` save without an agent turn. On the phone they're in the Pocket tab, ticked off with a swipe. Every key and setting is in [USING.md](docs/USING.md).

<p align="center">
  <img src="docs/images/hero.png" alt="The Mac popup in Todo mode next to an iPhone on its Pocket tab, showing todos: the same open todos, with reminder chips, on both" width="860">
</p>

## Privacy & security

- **Your data, your server.** Everything you write lives in your Supabase project, behind row-level security. The apps hold only its publishable key, and nobody else can sign up unless you allow their email. Your AI key is a secret on your server and never reaches the apps.
- **Encrypted push.** Your server sends pushes through the publisher's relay, encrypted with a key only your phone has. The relay sees ciphertext and stores nothing. iPhone Live Activity updates can't be encrypted, so they carry only a session's state and, when it needs you, whether for a question, an approval or a plan.
- **Terminal from the phone** is off by default. It runs over a Realtime channel only your account can join, and nothing it carries is stored. **Settings → Delete account** removes everything.

```mermaid
flowchart LR
  mac["Džep for Mac"]
  subgraph yours ["Your Supabase project"]
    direction TB
    db[("Your data<br/>row-level security")]
    fn["Functions<br/>ask · device · pair · push"]
  end
  phones["Your phones<br/>iPhone · Android"]
  ai["AI provider<br/>(your key)"]
  relay["Publisher's push relay<br/>ciphertext only"]
  apns["APNs / FCM"]
  mac <-->|"sync, Realtime"| db
  db <-->|"sync, Realtime"| phones
  fn -->|questions| ai
  fn -->|"encrypted push"| relay
  relay --> apns --> phones
```

The full policy is in [PRIVACY.md](docs/PRIVACY.md). Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Documentation

| | |
| --- | --- |
| [USING.md](docs/USING.md) | Every feature, key and setting, with screenshots |
| [SELF_HOSTING.md](docs/SELF_HOSTING.md) | The server by script, AI providers, sharing, updating, troubleshooting |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the pieces fit, and why some of them look odd |
| [BUILDING.md](docs/BUILDING.md) | Building the apps with your own signing identity, and the screenshots |
| [RELEASING.md](docs/RELEASING.md) | How releases are made |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Setting up the repo, and what a pull request needs |
| [SECURITY.md](SECURITY.md) | Reporting a vulnerability, and the security model |
| [PRIVACY.md](docs/PRIVACY.md) | What the apps send, and to whom |

## Contributing

Issues and pull requests are welcome; start with [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © Danijel Lovric
