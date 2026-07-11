#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

HELPER_IMAGE="alpine:3.22.1"

env_value() {
    grep "^$1=" .env | head -n 1 | cut -d= -f2-
}

query() {
    docker compose exec -T db psql -U supabase_admin -d postgres -Atc "$1"
}

email="restore-smoke-$(date -u +%s)@example.invalid"
password="Restore-$(openssl rand -hex 12)"
sentinel="restore-smoke-$(date -u +%s).txt"
public_url=$(env_value SUPABASE_PUBLIC_URL)
anon_key=$(env_value ANON_KEY)
response=$(mktemp)

status=$(curl -sS -o "$response" -w '%{http_code}' \
    -X POST \
    -H "apikey: $anon_key" \
    -H "Authorization: Bearer $anon_key" \
    -H "Content-Type: application/json" \
    --data "{\"email\":\"$email\",\"password\":\"$password\"}" \
    "$public_url/auth/v1/signup")

rm -f "$response"
case "$status" in
    200|201) ;;
    *) echo "Signup failed with HTTP $status" >&2; exit 1 ;;
esac

user_id=$(query "select id from auth.users where email = '$email'")
[ -n "$user_id" ] || { echo "Fixture user was not created" >&2; exit 1; }

docker run --rm \
    -v "$ROOT/volumes/storage:/target:z" \
    "$HELPER_IMAGE" \
    sh -c "printf 'restore fixture' > /target/$sentinel"

backup_output=$(./nuvio backup)
backup_dir=$(printf '%s\n' "$backup_output" | sed -n 's/^Backup written to //p' | tail -n 1)
[ -d "$backup_dir" ] || { echo "Backup directory was not created" >&2; exit 1; }

query "delete from auth.users where id = '$user_id'" >/dev/null
docker run --rm \
    -v "$ROOT/volumes/storage:/target:z" \
    "$HELPER_IMAGE" \
    rm -f "/target/$sentinel"

[ "$(query "select count(*) from auth.users where id = '$user_id'")" = "0" ] || {
    echo "Fixture user was not deleted before restore" >&2
    exit 1
}

./nuvio restore "$backup_dir" --yes

[ "$(query "select count(*) from auth.users where id = '$user_id'")" = "1" ] || {
    echo "Fixture user was not restored" >&2
    exit 1
}

[ "$(query "select count(*) from public.addons where user_id = '$user_id'")" = "2" ] || {
    echo "Fixture addons were not restored" >&2
    exit 1
}

sentinel_value=$(docker run --rm \
    -v "$ROOT/volumes/storage:/target:ro,z" \
    "$HELPER_IMAGE" \
    cat "/target/$sentinel")
[ "$sentinel_value" = "restore fixture" ] || {
    echo "Storage sentinel was not restored" >&2
    exit 1
}

query "delete from auth.users where id = '$user_id'" >/dev/null
docker run --rm \
    -v "$ROOT/volumes/storage:/target:z" \
    "$HELPER_IMAGE" \
    rm -f "/target/$sentinel"

echo "OK  database and Storage backup/restore"
