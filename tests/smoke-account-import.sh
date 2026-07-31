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
    token=$1
    function_name=$2
    body=$3
    curl --fail-with-body -sS \
        -X POST \
        -H "apikey: $anon_key" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        --data "$body" \
        "$public_url/rest/v1/rpc/$function_name"
}

email="account-import-smoke-$(date -u +%s)@example.invalid"
password="Import-$(openssl rand -hex 12)"
object_name="account-import-smoke-$(date -u +%s).png"
public_url=$(env_value SUPABASE_PUBLIC_URL)
anon_key=$(env_value ANON_KEY)
service_role_key=$(env_value SERVICE_ROLE_KEY)
user_id=""

cleanup() {
    curl -sS -o /dev/null \
        -X DELETE \
        -H "apikey: $service_role_key" \
        -H "Authorization: Bearer $service_role_key" \
        "$public_url/storage/v1/object/avatars/$object_name" || true
    if [ -n "$user_id" ]; then
        query "delete from auth.users where id = '$user_id'" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

signup=$(curl --fail-with-body -sS \
    -X POST \
    -H "apikey: $anon_key" \
    -H "Authorization: Bearer $anon_key" \
    -H "Content-Type: application/json" \
    --data "{\"email\":\"$email\",\"password\":\"$password\"}" \
    "$public_url/auth/v1/signup")
access_token=$(printf '%s' "$signup" | jq -er '.access_token')
user_id=$(printf '%s' "$signup" | jq -er '.user.id')

curl --fail-with-body -sS -o /dev/null \
    -X POST \
    -H "apikey: $service_role_key" \
    -H "Authorization: Bearer $service_role_key" \
    -H "Content-Type: image/png" \
    -H "x-upsert: true" \
    --data-binary '@assets/avatars/avatar_linear_red_v3.png' \
    "$public_url/storage/v1/object/avatars/$object_name"

avatar_url="$public_url/storage/v1/object/public/avatars/$object_name"
profile_payload=$(jq -cn --arg avatar_url "$avatar_url" '{
    p_profiles: [{
        profile_index: 1,
        name: "Imported Profile",
        avatar_color_hex: "#112233",
        uses_primary_addons: false,
        uses_primary_plugins: false,
        avatar_url: $avatar_url
    }],
    p_client_max_profiles: 6,
    p_origin_client_id: "account-import-smoke"
}')
rpc "$access_token" sync_push_profiles "$profile_payload" >/dev/null
rpc "$access_token" sync_push_library '{"p_items":[{"content_id":"tt-import-smoke","content_type":"movie","name":"Imported Movie","poster_shape":"POSTER","genres":["Drama"],"added_at":1760000000000}],"p_profile_id":1,"p_origin_client_id":"account-import-smoke"}' >/dev/null

# Make the trigger-seeded rows observably different from fresh defaults. A
# replace restore must preserve these exact values instead of colliding with or
# silently retaining defaults created by the restored profile insert.
query "update public.addons set name = 'Imported ' || name, enabled = false, sort_order = sort_order + 10 where user_id = '$user_id'" >/dev/null
source_addons=$(query "select coalesce(jsonb_agg(jsonb_build_array(profile_id, url, name, enabled, sort_order) order by profile_id, sort_order, url), '[]'::jsonb)::text from public.addons where user_id = '$user_id'")

printf '%s\n' "$password" | ./nuvio import-account \
    --source-url "$public_url" \
    --source-key "$anon_key" \
    --email "$email" \
    --yes

local_login=$(curl --fail-with-body -sS \
    -X POST \
    -H "apikey: $anon_key" \
    -H "Content-Type: application/json" \
    --data "{\"email\":\"$email\",\"password\":\"$password\"}" \
    "$public_url/auth/v1/token?grant_type=password")
local_access_token=$(printf '%s' "$local_login" | jq -er '.access_token')

profiles=$(rpc "$local_access_token" sync_pull_profiles '{}')
printf '%s' "$profiles" | jq -e --arg avatar_url "$avatar_url" \
    '.[] | select(.name == "Imported Profile" and .avatar_url == $avatar_url)' >/dev/null
library=$(rpc "$local_access_token" sync_pull_library '{"p_profile_id":1,"p_limit":100,"p_offset":0}')
printf '%s' "$library" | jq -e '.[] | select(.content_id == "tt-import-smoke" and .name == "Imported Movie")' >/dev/null
restored_addons=$(query "select coalesce(jsonb_agg(jsonb_build_array(profile_id, url, name, enabled, sort_order) order by profile_id, sort_order, url), '[]'::jsonb)::text from public.addons where user_id = '$user_id'")
[ "$restored_addons" = "$source_addons" ] || {
    echo "clean restore did not preserve the exported addon set" >&2
    exit 1
}
curl --fail -sS -o /dev/null -H "apikey: $anon_key" "$avatar_url"

echo "OK  official account import, login recreation, data restore, and Storage copy"
