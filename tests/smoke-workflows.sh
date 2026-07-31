#!/bin/sh

set -eu

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

env_value() {
    grep "^$1=" .env | head -n 1 | cut -d= -f2-
}

query() {
    docker compose exec -T db psql -U supabase_admin -d postgres -Atc "$1"
}

rpc() {
    function_name=$1
    body=$2
    curl --fail-with-body -sS \
        -X POST \
        -H "apikey: $anon_key" \
        -H "Authorization: Bearer $access_token" \
        -H "Content-Type: application/json" \
        --data "$body" \
        "$public_url/rest/v1/rpc/$function_name"
}

rpc_anon() {
    function_name=$1
    body=$2
    curl --fail-with-body -sS \
        -X POST \
        -H "apikey: $anon_key" \
        -H "Authorization: Bearer $anon_key" \
        -H "Content-Type: application/json" \
        --data "$body" \
        "$public_url/rest/v1/rpc/$function_name"
}

email="workflow-smoke-$(date -u +%s)@example.invalid"
password="Workflow-$(openssl rand -hex 12)"
public_url=$(env_value SUPABASE_PUBLIC_URL)
anon_key=$(env_value ANON_KEY)
signup_response=$(mktemp)
user_id=""

cleanup() {
    rm -f "$signup_response"
    if [ -n "$user_id" ]; then
        query "delete from auth.users where id = '$user_id'" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

curl --fail-with-body -sS \
    -X POST \
    -H "apikey: $anon_key" \
    -H "Authorization: Bearer $anon_key" \
    -H "Content-Type: application/json" \
    --data "{\"email\":\"$email\",\"password\":\"$password\"}" \
    "$public_url/auth/v1/signup" > "$signup_response"

access_token=$(jq -er '.access_token' "$signup_response")
user_id=$(jq -er '.user.id' "$signup_response")

device_registered=$(rpc register_current_device '{"p_installation_id":"workflow-smoke-device-123456","p_client_name":"Nuvio Mobile","p_client_version":"smoke","p_platform":"test","p_device_name":"Workflow Smoke"}')
printf '%s' "$device_registered" | jq -e '. == true' >/dev/null
echo "OK  device registration"

rpc sync_push_profiles '{"p_profiles":[{"profile_index":1,"name":"Smoke Profile","avatar_color_hex":"#336699","uses_primary_addons":false,"uses_primary_plugins":false}],"p_client_max_profiles":6,"p_origin_client_id":"selfhost-smoke"}' >/dev/null
profiles=$(rpc sync_pull_profiles '{}')
printf '%s' "$profiles" | jq -e '.[] | select(.profile_index == 1 and .name == "Smoke Profile")' >/dev/null
echo "OK  profile sync"

rpc sync_push_collections '{"p_profile_id":1,"p_collections_json":[{"id":"smoke-collection","name":"Smoke"}],"p_origin_client_id":"selfhost-smoke"}' >/dev/null
collections=$(rpc sync_pull_collections '{"p_profile_id":1}')
printf '%s' "$collections" | jq -e '.[0].collections_json[0].id == "smoke-collection"' >/dev/null

rpc sync_push_home_catalog_settings '{"p_profile_id":1,"p_settings_json":{"layout":"smoke"},"p_platform":"tv","p_origin_client_id":"selfhost-smoke"}' >/dev/null
home_settings=$(rpc sync_pull_home_catalog_settings '{"p_profile_id":1,"p_platform":"tv"}')
printf '%s' "$home_settings" | jq -e '.[0].settings_json.layout == "smoke"' >/dev/null

rpc sync_push_profile_settings_blob '{"p_profile_id":1,"p_settings_json":{"theme":"smoke"},"p_platform":"tv","p_origin_client_id":"selfhost-smoke"}' >/dev/null
profile_settings=$(rpc sync_pull_profile_settings_blob '{"p_profile_id":1,"p_platform":"tv"}')
printf '%s' "$profile_settings" | jq -e '.[0].settings_json.theme == "smoke"' >/dev/null
echo "OK  settings and collections sync"

rpc sync_push_library '{"p_items":[{"content_id":"tt-smoke-library","content_type":"movie","name":"Smoke Movie","poster":"https://example.com/poster.jpg","poster_shape":"POSTER","background":null,"description":"Synthetic test item","release_info":"2026","imdb_rating":8.0,"genres":["Drama"],"addon_base_url":"https://example.com/addon","added_at":1760000000000}],"p_profile_id":1,"p_origin_client_id":"selfhost-smoke"}' >/dev/null
library=$(rpc sync_pull_library '{"p_profile_id":1,"p_limit":100,"p_offset":0}')
printf '%s' "$library" | jq -e '.[] | select(.content_id == "tt-smoke-library" and .name == "Smoke Movie")' >/dev/null
library_cursor=$(rpc sync_get_library_delta_cursor '{"p_profile_id":1}')
printf '%s' "$library_cursor" | jq -e 'type == "number" and . > 0' >/dev/null
library_delta=$(rpc sync_pull_library_delta '{"p_profile_id":1,"p_since_event_id":0,"p_limit":100}')
printf '%s' "$library_delta" | jq -e '.[] | select(.operation == "upsert" and .content_id == "tt-smoke-library" and .name == "Smoke Movie")' >/dev/null
echo "OK  library full and delta sync"

rpc sync_push_watch_progress '{"p_entries":[{"content_id":"tt-smoke-progress","content_type":"movie","video_id":"smoke-video","position":90000,"duration":100000,"last_watched":1760000000000,"progress_key":"tt-smoke-progress"}],"p_profile_id":1,"p_origin_client_id":"selfhost-smoke"}' >/dev/null
progress=$(rpc sync_pull_watch_progress '{"p_profile_id":1,"p_since_last_watched":null,"p_limit":100}')
printf '%s' "$progress" | jq -e '.[] | select(.progress_key == "tt-smoke-progress" and .position == 90000)' >/dev/null

watched=$(rpc sync_pull_watched_items '{"p_profile_id":1,"p_page":1,"p_page_size":100}')
printf '%s' "$watched" | jq -e '.[] | select(.content_id == "tt-smoke-progress")' >/dev/null
echo "OK  watch progress and watched-items sync"

account_backup=$(rpc sync_export_account_backup '{}')
printf '%s' "$account_backup" | jq -e '.format == "nuvio_account_backup" and .version == 1 and .counts.profiles == 1 and .counts.library_items == 1' >/dev/null
echo "OK  account export"

tv_nonce="smoke-tv-device-nonce-123456"
tv_start=$(rpc_anon start_tv_login_session "{\"p_device_nonce\":\"$tv_nonce\",\"p_redirect_base_url\":\"https://nuvio.tv/tv-login\",\"p_device_name\":\"Smoke TV\"}")
tv_code=$(printf '%s' "$tv_start" | jq -er '.[0].code')
rpc approve_tv_login_session "{\"p_code\":\"$tv_code\"}" >/dev/null
tv_exchange=$(curl --fail-with-body -sS \
    -X POST \
    -H "apikey: $anon_key" \
    -H "Content-Type: application/json" \
    --data "{\"code\":\"$tv_code\",\"device_nonce\":\"$tv_nonce\"}" \
    "$public_url/functions/v1/tv-logins-exchange")
printf '%s' "$tv_exchange" | jq -e '.access_token | type == "string" and length > 20' >/dev/null
echo "OK  TV login exchange"

tracker_nonce="smoke-tracker-device-123456"
tracker_start=$(rpc start_tracker_tv_login_session "{\"p_tracker\":\"anilist\",\"p_device_nonce\":\"$tracker_nonce\",\"p_redirect_base_url\":\"https://nuvio.tv/tracker-login\"}")
tracker_code=$(printf '%s' "$tracker_start" | jq -er '.[0].code')
tracker_exchange=$(curl --fail-with-body -sS \
    -X POST \
    -H "apikey: $anon_key" \
    -H "Authorization: Bearer $access_token" \
    -H "Content-Type: application/json" \
    --data "{\"code\":\"$tracker_code\",\"tracker\":\"anilist\",\"access_token\":\"smoke-access-token\",\"refresh_token\":\"smoke-refresh-token\",\"expires_in\":3600,\"tracker_user_id\":\"smoke-user\",\"username\":\"Smoke\"}" \
    "$public_url/functions/v1/tracker-tv-logins-exchange")
printf '%s' "$tracker_exchange" | jq -e '.ok == true' >/dev/null
tracker_poll=$(rpc poll_tracker_tv_login_session "{\"p_tracker\":\"anilist\",\"p_code\":\"$tracker_code\",\"p_device_nonce\":\"$tracker_nonce\"}")
printf '%s' "$tracker_poll" | jq -e '.[0].status == "ready" and .[0].access_token == "smoke-access-token"' >/dev/null
echo "OK  tracker TV login exchange"

delete_response=$(curl --fail-with-body -sS \
    -X POST \
    -H "apikey: $anon_key" \
    -H "Authorization: Bearer $access_token" \
    -H "Content-Type: application/json" \
    --data '{}' \
    "$public_url/functions/v1/delete-account")
printf '%s' "$delete_response" | jq -e '.success == true' >/dev/null
[ "$(query "select count(*) from auth.users where id = '$user_id'")" = "0" ] || {
    echo "Account deletion did not remove the auth user" >&2
    exit 1
}
[ "$(query "select count(*) from public.watch_progress_events where user_id = '$user_id'")" = "0" ] || {
    echo "Account deletion left watch-progress events behind" >&2
    exit 1
}
user_id=""
echo "OK  account deletion"
