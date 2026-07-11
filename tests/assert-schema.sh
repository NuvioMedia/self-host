#!/bin/sh

set -eu

query() {
    docker compose exec -T db psql -U supabase_admin -d postgres -Atc "$1"
}

assert_count() {
    label=$1
    expected=$2
    actual=$3
    if [ "$actual" != "$expected" ]; then
        echo "$label: expected $expected, got $actual" >&2
        exit 1
    fi
    echo "OK  $label ($actual)"
}

assert_count "public tables" 20 "$(query "select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE'")"
assert_count "public RLS policies" 17 "$(query "select count(*) from pg_policies where schemaname='public'")"
assert_count "auth trigger" 1 "$(query "select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='auth' and c.relname='users' and t.tgname='on_auth_user_created_addons'")"

if [ "${1:-full}" = "database" ]; then
    assert_count "Nuvio database migrations" 2 "$(query "select count(*) from nuvio_migrations.schema_migrations")"
else
    assert_count "storage policies" 1 "$(query "select count(*) from pg_policies where schemaname='storage' and tablename='objects' and policyname='Public avatar read access'")"
    assert_count "storage buckets" 2 "$(query "select count(*) from storage.buckets where id in ('avatars', 'covers')")"
    assert_count "Nuvio migrations" 3 "$(query "select count(*) from nuvio_migrations.schema_migrations")"
fi
