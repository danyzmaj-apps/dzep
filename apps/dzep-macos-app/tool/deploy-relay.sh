#!/usr/bin/env bash
# Publisher only: deploys the push relay (supabase/functions/relay) to the
# project every Džep server sends its pushes through, with the APNs key and,
# for Android phones, the Firebase service account (FCM).
# Users never run this; their servers only call the relay (functions/push).
#
#   apps/dzep-macos-app/tool/deploy-relay.sh <project-ref> <AuthKey_XXXXXXXXXX.p8> <team-id> [bundle-id] \
#     [--fcm <firebase-service-account.json>]
#
# Without --fcm the FCM secret is left as it is (unset: the relay answers 501
# for Android phones).
set -euo pipefail

fcm=
args=()
while (($#)); do
  case $1 in
    --fcm) fcm=${2:?path to the Firebase service-account JSON}; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- ${args[@]+"${args[@]}"}

ref=${1:?project ref}
p8=${2:?path to the APNs .p8 key}
team=${3:?Apple team id}
topic=${4:-com.danyzmaj.dzep}
key_id=$(basename "$p8" .p8)
key_id=${key_id#AuthKey_}

secrets=(APNS_KEY="$(cat "$p8")" APNS_KEY_ID="$key_id" APNS_TEAM_ID="$team" APNS_TOPIC="$topic")
if [[ -n $fcm ]]; then
  project=$(jq -er '.project_id' "$fcm")
  secrets+=(FCM_SERVICE_ACCOUNT="$(cat "$fcm")")
fi

cd "$(dirname "$0")/.."
supabase secrets set --project-ref "$ref" "${secrets[@]}"
supabase functions deploy relay --project-ref "$ref" --no-verify-jwt
echo "Relay: https://$ref.supabase.co/functions/v1/relay (key $key_id, team $team, topic $topic${fcm:+, FCM project $project})"
