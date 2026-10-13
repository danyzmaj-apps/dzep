#!/usr/bin/env bash
# Publisher only: deploys the push relay (supabase/functions/relay) to the
# project every Džep server sends its pushes through, with the APNs key.
# Users never run this; their servers only call the relay (functions/push).
#
#   apps/dzep-macos-app/tool/deploy-relay.sh <project-ref> <AuthKey_XXXXXXXXXX.p8> <team-id> [bundle-id]
set -euo pipefail

ref=${1:?project ref}
p8=${2:?path to the APNs .p8 key}
team=${3:?Apple team id}
topic=${4:-com.danyzmaj.dzep}
key_id=$(basename "$p8" .p8)
key_id=${key_id#AuthKey_}

cd "$(dirname "$0")/.."
supabase secrets set --project-ref "$ref" \
  APNS_KEY="$(cat "$p8")" APNS_KEY_ID="$key_id" APNS_TEAM_ID="$team" APNS_TOPIC="$topic"
supabase functions deploy relay --project-ref "$ref" --no-verify-jwt
echo "Relay: https://$ref.supabase.co/functions/v1/relay (key $key_id, team $team, topic $topic)"
