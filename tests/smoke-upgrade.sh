#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

query() {
    docker compose exec -T db psql -U supabase_admin -d postgres -Atc "$1"
}

latest_migration=""
expected_migrations=0
for migration in database/migrations/*.sql; do
    latest_migration=$migration
    expected_migrations=$((expected_migrations + 1))
done

[ -n "$latest_migration" ] || { echo "No database migrations found" >&2; exit 1; }
latest_name=$(basename "$latest_migration")
latest_version=${latest_name%%_*}

[ "$(query "select exists(select 1 from nuvio_migrations.schema_migrations where version='$latest_version')")" = "f" ] || {
    echo "Latest migration is already applied; start from the database-bootstrap state" >&2
    exit 1
}

for migration in database/migrations/*.sql; do
    [ "$migration" = "$latest_migration" ] && continue
    name=$(basename "$migration")
    version=${name%%_*}
    applied=$(query "select exists(select 1 from nuvio_migrations.schema_migrations where version='$version')")
    if [ "$applied" = "f" ]; then
        echo "Applying pre-upgrade migration $name"
        docker compose exec -T db psql -v ON_ERROR_STOP=1 -U supabase_admin -d postgres < "$migration"
    fi
done

fixture_id="upgrade-smoke-$(date -u +%s)"
cleanup() {
    query "delete from public.avatar_catalog where id='$fixture_id'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

query "insert into public.avatar_catalog (id, display_name, storage_path, category) values ('$fixture_id', 'Upgrade Smoke', 'upgrade-smoke.png', 'test')" >/dev/null

./nuvio migrate

[ "$(query "select count(*) from nuvio_migrations.schema_migrations")" = "$expected_migrations" ] || {
    echo "Upgrade did not apply every migration" >&2
    exit 1
}
[ "$(query "select count(*) from public.avatar_catalog where id='$fixture_id'")" = "1" ] || {
    echo "Upgrade did not preserve existing application data" >&2
    exit 1
}

before=$(query "select count(*) from nuvio_migrations.schema_migrations")
./nuvio migrate >/dev/null
after=$(query "select count(*) from nuvio_migrations.schema_migrations")
[ "$after" = "$before" ] || {
    echo "Migration rerun was not idempotent" >&2
    exit 1
}

echo "OK  upgrade to $latest_name preserves data and is idempotent"
