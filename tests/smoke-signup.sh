#!/bin/sh

set -eu

env_value() {
    grep "^$1=" .env | head -n 1 | cut -d= -f2-
}

query() {
    docker compose exec -T db psql -U supabase_admin -d postgres -Atc "$1"
}

email="selfhost-smoke-$(date -u +%s)@example.invalid"
password="Smoke-$(openssl rand -hex 12)"
public_url=$(env_value SUPABASE_PUBLIC_URL)
anon_key=$(env_value ANON_KEY)
response=$(mktemp)
user_id=""

cleanup() {
    if [ -n "$user_id" ]; then
        query "delete from auth.users where id = '$user_id'" >/dev/null
    fi
    rm -f "$response"
}
trap cleanup EXIT

status=$(curl -sS -o "$response" -w '%{http_code}' \
    -X POST \
    -H "apikey: $anon_key" \
    -H "Authorization: Bearer $anon_key" \
    -H "Content-Type: application/json" \
    --data "{\"email\":\"$email\",\"password\":\"$password\"}" \
    "$public_url/auth/v1/signup")

case "$status" in
    200|201) ;;
    *)
        echo "Signup failed with HTTP $status" >&2
        sed -n '1,20p' "$response" >&2
        exit 1
        ;;
esac

user_id=$(query "select id from auth.users where email = '$email'")
[ -n "$user_id" ] || { echo "Signup did not create an auth user" >&2; exit 1; }

addon_count=$(query "select count(*) from public.addons where user_id = '$user_id'")
[ "$addon_count" = "2" ] || { echo "Expected 2 default addons, got $addon_count" >&2; exit 1; }

expected_catalog_url=$(env_value DEFAULT_CATALOG_URL)
actual_catalog_url=$(query "select url from public.addons where user_id = '$user_id' and name = 'Nuvio Catalog Addon'")
[ "$actual_catalog_url" = "$expected_catalog_url" ] || {
    echo "Expected catalog URL $expected_catalog_url, got $actual_catalog_url" >&2
    exit 1
}

echo "OK  signup and default addons"
