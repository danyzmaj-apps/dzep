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

# The secrets go to the CLI in a mode-600 file, never as arguments (any local
# user could read those with ps while it runs). One line each, single-quoted:
# the relay drops the PEM's line breaks anyway, and the service account goes
# in compact (its private key's \n stay escapes inside the JSON).
env_file=$(mktemp) && chmod 600 "$env_file"
trap 'rm -f "$env_file"' EXIT
{
  printf "APNS_KEY='%s'\n" "$(tr -d '\r\n' <"$p8")"
  printf "APNS_KEY_ID='%s'\nAPNS_TEAM_ID='%s'\nAPNS_TOPIC='%s'\n" "$key_id" "$team" "$topic"
} >"$env_file"
if [[ -n $fcm ]]; then
  project=$(jq -er '.project_id' "$fcm")
  account=$(jq -c . "$fcm")
  [[ $account != *"'"* ]] || { echo "deploy-relay: $fcm has a ' in it; the env file can't carry that" >&2; exit 1; }
  printf "FCM_SERVICE_ACCOUNT='%s'\n" "$account" >>"$env_file"
fi

cd "$(dirname "$0")/.."
supabase secrets set --project-ref "$ref" --env-file "$env_file"
supabase functions deploy relay --project-ref "$ref" --no-verify-jwt
echo "Relay: https://$ref.supabase.co/functions/v1/relay (key $key_id, team $team, topic $topic${fcm:+, FCM project $project})"
