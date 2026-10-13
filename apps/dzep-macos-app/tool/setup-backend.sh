#!/usr/bin/env bash
# Sets up your own Džep backend on a Supabase project you created at
# https://supabase.com/dashboard (the free plan is plenty): database, sign-in,
# edge functions and the AI key. Safe to run again, e.g. after pulling a new
# version (it applies new migrations and redeploys the functions).
#
#   apps/dzep-macos-app/tool/setup-backend.sh [project-ref]
#
# Needs the Supabase CLI (brew install supabase/tap/supabase), logged in
# (supabase login). Walkthrough: docs/SELF_HOSTING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31msetup: %s\033[0m\n' "$*" >&2; exit 1; }
ask() { # ask VAR "prompt" [default] [secret]
  local reply
  if [[ "${4:-}" == secret ]]; then read -rsp "$2: " reply && echo; else read -rp "$2${3:+ [$3]}: " reply; fi
  printf -v "$1" '%s' "${reply:-${3:-}}"
}

command -v supabase >/dev/null || die "install the Supabase CLI first: brew install supabase/tap/supabase"
supabase projects list >/dev/null 2>&1 || die "log in first: supabase login"

REF="${1:-}"
if [[ -z "$REF" ]]; then
  say "Your Supabase projects:"
  supabase projects list
  ask REF "Project ref (the id in https://<ref>.supabase.co)"
fi
[[ "$REF" =~ ^[a-z0-9]{20}$ ]] || die "'$REF' isn't a project ref (20 lowercase letters and digits)"
URL="https://$REF.supabase.co"

say "1/6  Linking $REF"
supabase link --project-ref "$REF"

say "2/6  GitHub sign-in"
ENV=supabase/.env
touch "$ENV" && chmod 600 "$ENV"
if grep -q '^GITHUB_CLIENT_SECRET=.' "$ENV"; then
  echo "Using the GitHub OAuth app in $ENV."
else
  cat <<EOF
Create a GitHub OAuth app: https://github.com/settings/applications/new
  Application name:            Džep
  Homepage URL:                https://github.com/danyzmaj-apps/dzep
  Authorization callback URL:  $URL/auth/v1/callback
Then generate a client secret on its page.
EOF
  ask GITHUB_CLIENT_ID "Client ID"
  ask GITHUB_CLIENT_SECRET "Client secret" "" secret
  [[ -n "$GITHUB_CLIENT_ID" && -n "$GITHUB_CLIENT_SECRET" ]] || die "both are needed"
  grep -v '^GITHUB_CLIENT_' "$ENV" >"$ENV.tmp" || true
  printf 'GITHUB_CLIENT_ID=%s\nGITHUB_CLIENT_SECRET=%s\n' "$GITHUB_CLIENT_ID" "$GITHUB_CLIENT_SECRET" >>"$ENV.tmp"
  mv "$ENV.tmp" "$ENV" && chmod 600 "$ENV"
fi

say "3/6  Database"
supabase db push --yes

say "4/6  Auth settings (GitHub, the dzep:// redirect, private sign-up)"
supabase config push --yes

say "5/6  Edge functions"
supabase functions deploy ask --no-verify-jwt
supabase functions deploy device --no-verify-jwt
supabase functions deploy pair --no-verify-jwt
supabase functions deploy push --no-verify-jwt

say "6/6  AI for quick questions"
if supabase secrets list 2>/dev/null | grep -q AI_API_KEY; then
  echo "AI_API_KEY is already set (change it with: supabase secrets set AI_API_KEY=…)."
else
  cat <<EOF
Any OpenAI-compatible API works. Examples:
  DeepSeek     https://api.deepseek.com        deepseek-flash   (default)
  OpenAI       https://api.openai.com/v1       gpt-5-mini
  OpenRouter   https://openrouter.ai/api/v1    anthropic/claude-haiku-4.5
Leave the key empty to skip; Ask then says the server has no AI key.
EOF
  ask AI_BASE_URL "API base URL" "https://api.deepseek.com"
  ask AI_MODEL "Model" "deepseek-flash"
  ask AI_API_KEY "API key" "" secret
  if [[ -n "$AI_API_KEY" ]]; then
    supabase secrets set "AI_BASE_URL=$AI_BASE_URL" "AI_MODEL=$AI_MODEL" "AI_API_KEY=$AI_API_KEY"
  fi
fi

KEYS=$(supabase projects api-keys --project-ref "$REF" -o json)
KEY=""
for i in $(seq 0 9); do
  type=$(plutil -extract "$i.type" raw - <<<"$KEYS" 2>/dev/null) || break
  if [[ "$type" == publishable ]]; then KEY=$(plutil -extract "$i.api_key" raw - <<<"$KEYS"); break; fi
done
[[ -n "$KEY" ]] || die "no publishable key on this project (Project Settings → API Keys → create one)"

curl -fsS "$URL/auth/v1/settings" -H "apikey: $KEY" | grep -q '"github":true' \
  || die "GitHub sign-in didn't turn on; check Authentication → Sign In / Providers in the dashboard"

LINK="dzep://setup?url=$(printf %s "$URL" | sed 's/:/%3A/g; s#/#%2F#g')&key=$KEY"
say "Done. Your backend is ready."
cat <<EOF

Connect Džep on this Mac by opening the setup link (or paste it into Džep's
setup screen). On the iPhone, open it from Notes or Messages, or copy it from
the Mac's Settings once you're signed in.

  $LINK

The first account to sign in owns this server; nobody else can sign up
unless you add their email (docs/SELF_HOSTING.md, "Sharing").
EOF
if [[ -d /Applications/Dzep.app ]]; then
  ask OPEN "Open it in Džep now? (y/n)" "y"
  [[ "$OPEN" == y* ]] && open "$LINK"
fi
