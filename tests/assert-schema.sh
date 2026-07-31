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

assert_count "public tables" 21 "$(query "select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE'")"
assert_count "public RLS policies" 18 "$(query "select count(*) from pg_policies where schemaname='public'")"
assert_count "auth trigger" 1 "$(query "select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='auth' and c.relname='users' and t.tgname='on_auth_user_created_addons'")"

if [ "${1:-full}" = "database" ]; then
    assert_count "Nuvio database migrations" 2 "$(query "select count(*) from nuvio_migrations.schema_migrations")"
else
    assert_count "storage policies" 1 "$(query "select count(*) from pg_policies where schemaname='storage' and tablename='objects' and policyname='Public avatar read access'")"
    assert_count "storage buckets" 2 "$(query "select count(*) from storage.buckets where id in ('avatars', 'covers')")"
    assert_count "Nuvio migrations" 9 "$(query "select count(*) from nuvio_migrations.schema_migrations")"
    assert_count "private settings" 1 "$(query "select count(*) from nuvio_private.instance_settings where key='default_catalog_url'")"
    assert_count "avatar catalog entries" 41 "$(query "select count(*) from public.avatar_catalog where is_active")"
    assert_count "avatar catalog objects" 41 "$(query "select count(*) from public.avatar_catalog a join storage.objects o on o.bucket_id='avatars' and o.name=a.storage_path where a.is_active")"
    assert_count "anonymous RPC allowlist" 4 "$(query "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and has_function_privilege('anon', p.oid, 'EXECUTE')")"
    assert_count "authenticated session/library RPCs" 8 "$(query "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname = any(array['list_my_sessions','register_current_device','register_current_session','revoke_my_session','sync_delete_library_items','sync_get_library_delta_cursor','sync_pull_library_delta','sync_push_library_items']) and has_function_privilege('authenticated', p.oid, 'EXECUTE')")"
    assert_count "exposed internal RPCs" 0 "$(query "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('cleanup_anonymous_users','consume_tv_login_session','emit_sync_invalidation','nuvio_default_catalog_url') and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))")"
    assert_count "unhardened security definer functions" 0 "$(query "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef and coalesce(array_to_string(p.proconfig, ','), '') not like 'search_path=pg_catalog, public, auth, extensions, pg_temp%'")"
fi
