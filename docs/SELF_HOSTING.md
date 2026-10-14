# Self-hosting

Džep has no central server. Your ideas, todos and chats live in a Supabase project that you own, and the apps connect to it. This takes a few minutes, once. The free Supabase plan is more than enough for one person.

## The easy way: the Mac app

Install Džep and open it. With no server yet, it starts a setup wizard:

1. **Supabase access token.** Create one at [supabase.com/dashboard/account/tokens](https://supabase.com/dashboard/account/tokens) (`sbp_…`) and paste it. It's used for this setup only and never saved.
2. **Project.** Let Džep create one (region guessed from your time zone), or pick one you have. A project of its own is best: Džep won't go on one that already has accounts or tables of the same names, and says which of its settings it would replace. The free plan allows two active projects; pause one you don't use if it's full.
3. **GitHub sign-in.** Džep opens GitHub's "new OAuth app" form with the name and callback URL filled in; paste back the client ID and secret.
4. **AI (optional).** DeepSeek, OpenAI, OpenRouter or any OpenAI-compatible API, with its key.
5. **Setup.** Džep creates the tables and security rules, turns on GitHub sign-in (and turns email sign-up off: GitHub is the only way in), private sign-up and the `dzep://` redirect, deploys the `ask`, `device`, `pair` and `push` functions and stores the AI key as a function secret. If a step fails, **Retry** resumes from it, and redoes any step whose values you changed after **← Back**. Push notifications need nothing more: each phone registers itself, and your server sends through the app publisher's relay, encrypted so only that phone can read them ([Push](#push)).

Then sign in with GitHub. For your phones, see [Connect the apps](#connect-the-apps).

Servers are set up from the Mac (or the script below), never from a phone: the iPhone and Android apps only pair with a server that exists.

## The script

Same result from a terminal. You need:

- a [Supabase](https://supabase.com) account,
- a GitHub account (Džep signs in with GitHub),
- the [Supabase CLI](https://supabase.com/docs/guides/cli): `brew install supabase/tap/supabase`, then `supabase login`,
- `jq` (part of macOS 15 and later; otherwise `brew install jq`, or your Linux package manager's `jq`): the script runs on Linux too,
- this repository: `git clone https://github.com/danyzmaj-apps/dzep && cd dzep`,
- optionally, an API key for any OpenAI-compatible AI provider, for quick questions.

### 1. Create a Supabase project

At [supabase.com/dashboard](https://supabase.com/dashboard), choose **New project**. Pick a region near you and keep the database password somewhere safe; Džep itself never needs it. Note the project ref: it's the `abcdefghijklmnopqrst` in `https://abcdefghijklmnopqrst.supabase.co`.

### 2. Run the setup script

```sh
# in the repo root
apps/dzep-macos-app/tool/setup-backend.sh <project-ref>
```

It walks you through the rest:

1. It links the repo to your project.
2. It asks you to **create a GitHub OAuth app** at [github.com/settings/applications/new](https://github.com/settings/applications/new), with the callback URL `https://<project-ref>.supabase.co/auth/v1/callback`, and to paste its client ID and secret. They are stored in `apps/dzep-macos-app/supabase/.env`, which git ignores. Secrets reach the Supabase CLI through a temporary mode-600 env file, never the command line.
3. It creates the tables, security rules and storage (`supabase db push`).
4. It turns on GitHub sign-in, the `dzep://` redirect and private sign-up, and turns email sign-up off (`supabase config push`).
5. It deploys the edge functions: `ask`, `device`, `pair` and `push`.
6. It asks for your AI provider (see [AI provider](#ai-provider)). You can skip this.

At the end it prints a **setup link**: `dzep://setup?url=…&key=…`. It holds only your project URL and its publishable key, both of which are safe in an app; row-level security protects your data. It's for the Mac: phones need the Mac's code, which adds a sign-in code to the same link.

## Connect the apps

- **Mac**: install Džep from [Releases](https://github.com/danyzmaj-apps/dzep/releases/latest), then open the setup link (the script offers to) or paste it into Džep's setup screen (**I already have one: connect it**). Sign in with GitHub.
- **iPhone and Android**: phones sign in only with a code from your Mac, never with GitHub. On the Mac, **Settings → Set up phone…** shows a QR code. In the phone app, tap **Scan the code from your Mac**. The code carries the server address, its publishable key and a one-time sign-in code, so the phone signs in as you. It works once and expires after 10 minutes; anyone who scans it gets into your account, so only show it to your own phone. No camera? **Paste a code instead** takes the same code as text (the whole `dzep://setup?…&code=…` link). A phone that signs out, or whose sign-in ends, is back on that screen and needs a new code.

The first account that signs in **owns the server**.

## App Store and Play review

Reviewers can't scan your Mac, and must not get into your account. On the Mac, **Settings → Reviewer access → Codes…** makes a **reviewer code**: it signs a phone into a separate demo account on your server (`reviewer@<project-ref>.dzep.invalid`, made the first time), works as often as needed for 7, 30 or 90 days, and can be revoked there at any time. Give the reviewer its link (**Copy**) or its QR (**Save QR as PNG**); in the phone app it goes into **Paste a code instead**, or the camera reads the QR. The code is shown only when it's made: your server keeps a hash of it.

The demo account sees none of your ideas, todos, notes or chats, but Ask works for it, on your AI key, so revoke the code when the review is done. Once no code of it works, the demo account is shut out: revoking the last working code signs every phone on it out within 30 seconds, a code running out does the same within 10 minutes, and Ask turns it away from then on. If a reviewer taps **Delete account**, the demo account is emptied but stays, with your reviewer codes, so a code you gave Apple or Google keeps working for the next review. No email is ever sent to the demo address, and it isn't let in through `allowed_signups`: the `pair` function makes it with the service role.

## AI provider

Quick questions work with any OpenAI-compatible chat API. Set these as edge function secrets (the setup wizard and the setup script do it for you):

| Secret | Default | Examples |
| --- | --- | --- |
| `AI_API_KEY` | (none: Ask shows "No AI connected yet" and how to connect one) | your provider's key |
| `AI_BASE_URL` | `https://api.deepseek.com` | `https://api.openai.com/v1`, `https://openrouter.ai/api/v1`, `https://api.groq.com/openai/v1`, `http://<your-host>:11434/v1` (Ollama) |
| `AI_MODEL` | `deepseek-flash` | `gpt-5-mini`, `anthropic/claude-haiku-4.5`, `llama-3.3-70b-versatile` |
| `AI_EXTRA_BODY` | `{"thinking":{"type":"disabled"}}` on DeepSeek, else `{}` | any JSON object merged into each request, e.g. `{"temperature":0.3}` |

### Connect or switch it later

Skipped it during setup, or want another provider? On the Mac, open **Settings → AI → Connect…** (or **Connect an AI…** in Ask). Pick DeepSeek, OpenAI, OpenRouter or **Other** (any OpenAI-compatible URL and model), paste the API key, and paste a Supabase [access token](https://supabase.com/dashboard/account/tokens). Džep uses the token once to save the three secrets on your project and doesn't keep it; you can delete the token afterwards. The Mac and your phones pick up the change by themselves (a phone when it next comes to the front). This works for projects on supabase.com; on a server you run yourself, use the CLI.

From a terminal:

```sh
# in apps/dzep-macos-app (linked to your project by the setup script)
supabase secrets set AI_BASE_URL=https://api.openai.com/v1 AI_MODEL=gpt-5-mini AI_API_KEY=sk-…
```

No redeploy is needed. The key never leaves your server, and the apps never see it: they only ask the `ask` function whether a key is set and which model it uses.

## Sharing

A Džep server is private. The first account to sign up owns it, and anyone else's sign-in is refused with "This Džep server is private". To let someone in, add their GitHub email in the dashboard's SQL editor:

```sql
insert into public.allowed_signups (email) values ('friend@example.com');
```

Each person sees only their own data, but they share your AI key and your Supabase quota.

## Updating

After pulling a new version of this repo, run the setup script again. It applies new migrations and redeploys the functions, and it leaves your GitHub app and AI key as they are:

```sh
# in the repo root
git pull && apps/dzep-macos-app/tool/setup-backend.sh <project-ref>
```

The Mac app updates itself. Release notes say when a new app version needs a backend update.

## Push

Your server pushes reminders, coding-session notifications (a run ended, the agent needs you) and the state of the sessions you follow to your phones. Only the app's publisher holds the credentials that reach Džep's installs (the APNs key for iPhones, the Firebase service account for Android), so your server's `push` function hands each notification to the publisher's **relay**, which passes it to Apple's APNs or Google's Firebase Cloud Messaging.

- Each phone makes its own AES-256 key and registers it with your server (`push_devices`, with the device's push token and its `platform`, `ios` or `android`). Your server encrypts every notification with that key; the relay sees the push token, the kind of notification (reminder, terminal or activity), a collapse id and ciphertext, and stores nothing. iPhone Live Activity updates are the exception: iOS can't decrypt them, so they carry the coding session's state (working, needs you, finished) in the clear, and no text.
- Android messages are FCM data messages the app decrypts itself; iPhone messages are decrypted by its notification service extension.
- No setup on your side: the default `PUSH_RELAY_URL` is the publisher's relay.

### Your own app id and relay

A relay only reaches apps signed with the publisher's ids. A fork that ships its own app (its own bundle id or Android package) runs its own relay on a Supabase project of its own: an APNs key from its Apple team, a Firebase project with its Android app (its `google-services.json` goes into its Android build) and that project's service account as the relay's `FCM_SERVICE_ACCOUNT` secret. `apps/dzep-macos-app/tool/deploy-relay.sh` deploys it ([RELEASING.md](RELEASING.md#push-relay-once-and-after-relay-changes)). Then set `PUSH_RELAY_URL=https://<relay-project-ref>.supabase.co/functions/v1/relay` as a function secret on each server that serves those apps.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| "GitHub sign-in is off on this project" (Mac) | Run the setup script again, or turn GitHub on under Authentication → Sign In / Providers. |
| The browser shows `redirect_uri is not associated` | The GitHub OAuth app's callback URL must be exactly `https://<ref>.supabase.co/auth/v1/callback`. |
| Sign-in finishes in the browser but the app stays signed out | Authentication → URL Configuration must allow `dzep://login-callback` (`supabase config push` sets it). |
| "This Džep server is private" | Expected for everyone but the owner; see [Sharing](#sharing). |
| Phone: "That code doesn't work" | It ran out (10 minutes), was used already or was revoked: make a new one on the Mac (**Settings → Set up phone…**). |
| Phone: "Too many tries" | Ten wrong codes from one place in ten minutes: wait a few minutes, then use a fresh code. |
| Phone: "Your server is older than this app" | Run the setup script again (or update from the Mac's wizard): the server needs the new `pair` function and migration. |
| Ask: "No AI is connected yet. Connect one from Džep on your Mac: Settings → AI." | Connect one from the Mac's **Settings → AI**, or set `AI_API_KEY` (see [AI provider](#ai-provider)). |
| Ask: "… rejected the server's API key" / "doesn't know the model" | Check `AI_API_KEY` / `AI_MODEL` for your provider. |
| "The project refused this key" on the setup screen | Use the **publishable** key (Project Settings → API Keys), never a secret one. |
| Terminal: "Džep may not control iTerm2" (or Terminal, Ghostty) | Allow it in System Settings → Privacy & Security → Automation → Džep. |
| Terminal: "kitty isn't listening" | On the Mac, **Settings → Terminals → Set up…** next to kitty, then restart kitty. |
| Terminal: Ghostty windows show no screen | Expected: Ghostty's screen can't be read. Install tmux (`brew install tmux`) and start sessions from the phone: they run inside tmux with full control. |
| Terminal: can't answer or press keys in a Terminal (macOS) window | Expected: Terminal takes only whole lines. Same fix: install tmux and start sessions from the phone. |
| Terminal: a Ghostty session isn't matched to its window | Ghostty tells no tty, so Džep matches the session by its folder: keep one Ghostty window per folder. |
| Terminal: closing a Ghostty window from the phone asks on the Mac first | Ghostty confirms closing a window that runs something. Windows Džep opened (and ones an agent reported) are closed without asking; for others, confirm on the Mac or quit what runs in it first. |

A local Supabase (`supabase start`) works for development, but it doesn't check API keys, so the setup screen accepts any key there.

## Removing it

Delete your account in the app's Settings to erase your data, or delete the whole Supabase project in its dashboard. Then delete the GitHub OAuth app. If you keep the project, remember that with your account gone the next GitHub sign-in owns the server (and your AI key): delete the OAuth app first, and unset the key (`supabase secrets unset AI_API_KEY`), or delete the project.
