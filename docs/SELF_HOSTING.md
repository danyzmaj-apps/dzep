# Self-hosting

Džep has no central server. Your ideas, todos and chats live in a Supabase project that you own, and the apps connect to it. This takes a few minutes, once. The free Supabase plan is more than enough for one person.

## The easy way: the Mac app

Install Džep and open it. With no server yet, it starts a setup wizard:

1. **Supabase access token.** Create one at [supabase.com/dashboard/account/tokens](https://supabase.com/dashboard/account/tokens) (`sbp_…`) and paste it. It's used for this setup only and never saved.
2. **Project.** Pick an existing project or let Džep create one (region guessed from your time zone).
3. **GitHub sign-in.** Džep opens GitHub's "new OAuth app" form with the name and callback URL filled in; paste back the client ID and secret.
4. **AI (optional).** DeepSeek, OpenAI, OpenRouter or any OpenAI-compatible API, with its key.
5. **Setup.** Džep creates the tables and security rules, turns on GitHub sign-in, private sign-up and the `dzep://` redirect, deploys the `ask`, `device` and `pair` functions and stores the AI key as a function secret. If a step fails, **Try again** resumes from it.

Then sign in with GitHub. For the iPhone, see [Connect the apps](#connect-the-apps).

## The script

Same result from a terminal. You need:

- a [Supabase](https://supabase.com) account,
- a GitHub account (Džep signs in with GitHub),
- the [Supabase CLI](https://supabase.com/docs/guides/cli): `brew install supabase/tap/supabase`, then `supabase login`,
- this repository: `git clone https://github.com/danyzmaj-apps/dzep && cd dzep`,
- optionally, an API key for any OpenAI-compatible AI provider, for quick questions.

### 1. Create a Supabase project

At [supabase.com/dashboard](https://supabase.com/dashboard), choose **New project**. Pick a region near you and keep the database password somewhere safe; Džep itself never needs it. Note the project ref: it's the `abcdefghijklmnopqrst` in `https://abcdefghijklmnopqrst.supabase.co`.

### 2. Run the setup script

```sh
tool/setup-backend.sh <project-ref>
```

It walks you through the rest:

1. It links the repo to your project.
2. It asks you to **create a GitHub OAuth app** at [github.com/settings/applications/new](https://github.com/settings/applications/new), with the callback URL `https://<project-ref>.supabase.co/auth/v1/callback`, and to paste its client ID and secret. They are stored in `supabase/.env`, which git ignores.
3. It creates the tables, security rules and storage (`supabase db push`).
4. It turns on GitHub sign-in, the `dzep://` redirect and private sign-up (`supabase config push`).
5. It deploys the edge functions: `ask`, `device` and `pair`.
6. It asks for your AI provider (see [AI provider](#ai-provider)). You can skip this.

At the end it prints a **setup link**: `dzep://setup?url=…&key=…`. It holds only your project URL and its publishable key, both of which are safe in an app; row-level security protects your data.

## Connect the apps

- **Mac**: install Džep from [Releases](https://github.com/danyzmaj-apps/dzep/releases/latest), then open the setup link (the script offers to) or paste it into Džep's setup screen (**I already have one: connect it**). Sign in with GitHub.
- **iPhone**: on the Mac, **Settings → Set up iPhone…** shows a QR code. In the iPhone app, tap **Scan the code from your Mac**. The code carries the server address, its publishable key and a one-time sign-in code, so the phone signs in as you without GitHub. It works once and expires after 10 minutes; anyone who scans it gets into your account, so only show it to your own phone. No camera? **Paste a setup link instead** takes the same link.

The first account that signs in **owns the server**.

## AI provider

Quick questions work with any OpenAI-compatible chat API. Set these as edge function secrets (the setup script does it for you):

| Secret | Default | Examples |
| --- | --- | --- |
| `AI_API_KEY` | (none: Ask says the server has no key) | your provider's key |
| `AI_BASE_URL` | `https://api.deepseek.com` | `https://api.openai.com/v1`, `https://openrouter.ai/api/v1`, `https://api.groq.com/openai/v1`, `http://<your-host>:11434/v1` (Ollama) |
| `AI_MODEL` | `deepseek-flash` | `gpt-5-mini`, `anthropic/claude-haiku-4.5`, `llama-3.3-70b-versatile` |
| `AI_EXTRA_BODY` | `{"thinking":{"type":"disabled"}}` on DeepSeek, else `{}` | any JSON object merged into each request, e.g. `{"temperature":0.3}` |

To switch providers later:

```sh
supabase secrets set AI_BASE_URL=https://api.openai.com/v1 AI_MODEL=gpt-5-mini AI_API_KEY=sk-…
```

No redeploy is needed. The key never leaves your server, and the apps never see it.

## Sharing

A Džep server is private. The first account to sign up owns it, and anyone else's sign-in is refused with "This Džep server is private". To let someone in, add their GitHub email in the dashboard's SQL editor:

```sql
insert into public.allowed_signups (email) values ('friend@example.com');
```

Each person sees only their own data, but they share your AI key and your Supabase quota.

## Updating

After pulling a new version of this repo, run the setup script again. It applies new migrations and redeploys the functions, and it leaves your GitHub app and AI key as they are:

```sh
git pull && tool/setup-backend.sh <project-ref>
```

The Mac app updates itself. Release notes say when a new app version needs a backend update.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| "GitHub sign-in is off on this project" | Run the setup script again, or turn GitHub on under Authentication → Sign In / Providers. |
| The browser shows `redirect_uri is not associated` | The GitHub OAuth app's callback URL must be exactly `https://<ref>.supabase.co/auth/v1/callback`. |
| Sign-in finishes in the browser but the app stays signed out | Authentication → URL Configuration must allow `dzep://login-callback` (`supabase config push` sets it). |
| "This Džep server is private" | Expected for everyone but the owner; see [Sharing](#sharing). |
| Ask: "The server has no AI key yet" | Set `AI_API_KEY` (see [AI provider](#ai-provider)). |
| Ask: "… rejected the server's API key" / "doesn't know the model" | Check `AI_API_KEY` / `AI_MODEL` for your provider. |
| "The project refused this key" on the setup screen | Use the **publishable** key (Project Settings → API Keys), never a secret one. |

A local Supabase (`supabase start`) works for development, but it doesn't check API keys, so the setup screen accepts any key there.

## Removing it

Delete your account in the app's Settings to erase your data, or delete the whole Supabase project in its dashboard. Then delete the GitHub OAuth app.
