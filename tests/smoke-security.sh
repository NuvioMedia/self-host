#!/bin/sh

set -eu

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

env_value() {
    grep "^$1=" .env | head -n 1 | cut -d= -f2-
}

query() {
    docker compose exec -T db psql -U supabase_admin -d postgres -Atc "$1"
}

request_rpc() {
    token=$1
    function_name=$2
    body=$3
    curl -sS -o "$response" -w '%{http_code}' \
        -X POST \
        -H "apikey: $anon_key" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        --data "$body" \
        "$public_url/rest/v1/rpc/$function_name"
}

assert_allowed() {
    status=$(request_rpc "$1" "$2" "$3")
    case "$status" in
        200|204) ;;
        *)
            echo "$2 should be callable, got HTTP $status: $(cat "$response")" >&2
            exit 1
            ;;
    esac
}

assert_denied() {
    status=$(request_rpc "$1" "$2" "$3")
    case "$status" in
        401|403|404) ;;
        *)
            echo "$2 should be private, got HTTP $status: $(cat "$response")" >&2
            exit 1
            ;;
    esac
}

email="security-smoke-$(date -u +%s)@example.invalid"
password="Security-$(openssl rand -hex 12)"
public_url=$(env_value SUPABASE_PUBLIC_URL)
anon_key=$(env_value ANON_KEY)
response=$(mktemp)
user_id=""

cleanup() {
    rm -f "$response"
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

assert_allowed "$anon_key" health_ping '{}'
assert_allowed "$anon_key" get_avatar_catalog '{}'
assert_denied "$anon_key" cleanup_anonymous_users '{}'
assert_denied "$anon_key" sync_export_account_backup '{}'

assert_allowed "$access_token" sync_pull_profiles '{}'
assert_denied "$access_token" cleanup_anonymous_users '{}'
assert_denied "$access_token" consume_tv_login_session \
    '{"p_code":"not-a-code","p_device_nonce":"not-a-nonce"}'
assert_denied "$access_token" emit_sync_invalidation \
    "{\"p_user_id\":\"$user_id\",\"p_profile_id\":1,\"p_surface\":\"forbidden\",\"p_metadata\":{}}"
assert_denied "$access_token" nuvio_default_catalog_url '{}'

echo "OK  public RPC allowlist and private helpers"
