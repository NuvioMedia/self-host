#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

DEFAULT_NUVIO_CLOUD_URL="https://api.nuvio.tv"
DEFAULT_NUVIO_CLOUD_PUBLISHABLE_KEY="sb_publishable_1Clq8rlTVACkdcZuqr6_AD__xUUC_EN"

die() {
    echo "Error: $*" >&2
    exit 1
}

env_value() {
    grep "^$1=" .env | head -n 1 | cut -d= -f2-
}

validate_http_url() {
    value=$1
    label=$2
    case "$value" in
        ""|*[[:space:]]*) die "$label must be an http:// or https:// URL without spaces" ;;
        http://*|https://*) ;;
        *) die "$label must be an http:// or https:// URL" ;;
    esac
}

validate_header_token() {
    value=$1
    label=$2
    case "$value" in
        ""|*[!A-Za-z0-9._-]*) die "$label has an invalid value" ;;
    esac
}

json_string() {
    jq -Rs .
}

api_error() {
    response_file=$1
    message=$(jq -r '
        if type == "object" then
            .msg // .message // .error_description //
            (if (.error | type) == "string" then .error else empty end) //
            "request failed"
        else
            "request failed"
        end
    ' "$response_file" 2>/dev/null || printf 'request failed')
    printf '%s' "$message" | tr '\r\n' '  ' | cut -c1-240
}

write_curl_config() {
    curl_api_key=$1
    curl_bearer=$2
    curl_content_type=$3

    validate_header_token "$curl_api_key" "API key"
    if [ -n "$curl_bearer" ]; then
        validate_header_token "$curl_bearer" "access token"
    fi

    {
        printf 'silent\n'
        printf 'show-error\n'
        printf 'connect-timeout = 15\n'
        printf 'header = "apikey: %s"\n' "$curl_api_key"
        if [ -n "$curl_bearer" ]; then
            printf 'header = "Authorization: Bearer %s"\n' "$curl_bearer"
        fi
        if [ -n "$curl_content_type" ]; then
            printf 'header = "Content-Type: %s"\n' "$curl_content_type"
        fi
    } > "$import_tmp/curl.conf"
}

api_request() {
    method=$1
    url=$2
    api_key=$3
    bearer=$4
    output=$5

    write_curl_config "$api_key" "$bearer" "application/json"
    status=$(curl \
        --config "$import_tmp/curl.conf" \
        --request "$method" \
        --url "$url" \
        --data-binary @- \
        --output "$output" \
        --write-out '%{http_code}') || die "could not reach $url"
    : > "$import_tmp/curl.conf"
    printf '%s\n' "$status"
}

download_storage_object() {
    url=$1
    api_key=$2

    write_curl_config "$api_key" "" ""
    curl \
        --config "$import_tmp/curl.conf" \
        --fail \
        --request GET \
        --url "$url" \
        --output "$import_tmp/storage-object" || die "could not download a referenced official Storage object"
    : > "$import_tmp/curl.conf"
}

upload_storage_object() {
    relative_path=$1
    content_type=$2
    api_key=$3
    local_api_url=$4

    write_curl_config "$api_key" "$api_key" "$content_type"
    status=$(curl \
        --config "$import_tmp/curl.conf" \
        --request POST \
        --url "$local_api_url/storage/v1/object/$relative_path" \
        --header 'Cache-Control: public, max-age=3600' \
        --header 'x-upsert: true' \
        --data-binary "@$import_tmp/storage-object" \
        --output "$import_tmp/storage-response.json" \
        --write-out '%{http_code}') || die "could not upload a referenced Storage object"
    : > "$import_tmp/curl.conf"

    case "$status" in
        200|201) ;;
        *) die "local Storage upload failed with HTTP $status: $(api_error "$import_tmp/storage-response.json")" ;;
    esac
}

copy_referenced_storage() {
    backup_file=$1
    source_url=$2
    source_key=$3
    target_public_url=$4
    target_service_key=$5
    local_api_url=$6

    source_prefix="$source_url/storage/v1/object/public/"
    target_prefix="$target_public_url/storage/v1/object/public/"

    jq -r --arg prefix "$source_prefix" '
        [.. | strings | select(startswith($prefix))] | unique[]
    ' "$backup_file" > "$import_tmp/storage-urls"

    copied_storage_count=0
    while IFS= read -r object_url || [ -n "$object_url" ]; do
        [ -n "$object_url" ] || continue
        relative_path=${object_url#"$source_prefix"}
        lowercase_path=$(printf '%s' "$relative_path" | tr '[:upper:]' '[:lower:]')

        case "$relative_path" in
            avatars/*|covers/*) ;;
            *) continue ;;
        esac
        case "$lowercase_path" in
            *\?*|*\#*|*%2e*|*%2f*|*%5c*|*\\*|..|../*|*/../*|*/..|*//* )
                die "a referenced Storage object has an unsafe path"
                ;;
        esac
        [ -n "${relative_path#*/}" ] || die "a referenced Storage object has an empty path"

        case "$lowercase_path" in
            *.png) content_type="image/png" ;;
            *.jpg|*.jpeg) content_type="image/jpeg" ;;
            *.webp) content_type="image/webp" ;;
            avatars/*) die "an official avatar uses an unsupported file type" ;;
            *.gif) content_type="image/gif" ;;
            *) content_type="application/octet-stream" ;;
        esac

        download_storage_object "$object_url" "$source_key"
        object_size=$(wc -c < "$import_tmp/storage-object" | tr -d ' ')
        case "$object_size" in
            ""|*[!0-9]*) die "could not determine a Storage object's size" ;;
        esac
        [ "$object_size" -le 5242880 ] || die "a referenced Storage object exceeds the 5 MB import limit"

        upload_storage_object "$relative_path" "$content_type" "$target_service_key" "$local_api_url"
        copied_storage_count=$((copied_storage_count + 1))
    done < "$import_tmp/storage-urls"

    jq --arg source "$source_prefix" --arg target "$target_prefix" '
        walk(
            if type == "string" and
                (startswith($source + "avatars/") or startswith($source + "covers/"))
            then $target + ltrimstr($source)
            else .
            end
        )
    ' "$backup_file" > "$import_tmp/backup-rewritten.json"
    mv "$import_tmp/backup-rewritten.json" "$backup_file"
}

read_account_password() {
    printf 'Official Nuvio password: ' >&2
    if [ -t 0 ]; then
        terminal_echo_disabled=1
        stty -echo
        IFS= read -r account_password || die "could not read the password"
        stty echo
        terminal_echo_disabled=0
    else
        IFS= read -r account_password || die "could not read the password"
    fi
    printf '\n' >&2
    [ -n "$account_password" ] || die "password cannot be empty"
}

usage() {
    cat <<'EOF'
Usage: ./nuvio import-account [options]

Options:
  --email EMAIL       Official Nuvio account email (password is always prompted)
  --yes               Replace existing local application data without confirmation
  --skip-storage      Leave referenced official Storage URLs unchanged
  --source-url URL    Override the official Nuvio backend URL
  --source-key KEY    Override the official Nuvio publishable key
  -h, --help          Show this help
EOF
}

source_url=${NUVIO_CLOUD_URL:-}
source_key=${NUVIO_CLOUD_PUBLISHABLE_KEY:-}
account_email=""
assume_yes=0
skip_storage=0

while [ $# -gt 0 ]; do
    case "$1" in
        --email) [ $# -ge 2 ] || die "--email needs a value"; account_email=$2; shift 2 ;;
        --yes) assume_yes=1; shift ;;
        --skip-storage) skip_storage=1; shift ;;
        --source-url) [ $# -ge 2 ] || die "--source-url needs a value"; source_url=$2; shift 2 ;;
        --source-key) [ $# -ge 2 ] || die "--source-key needs a value"; source_key=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown import option: $1" ;;
    esac
done

[ -f .env ] || die "not configured; run ./nuvio setup first"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq >/dev/null 2>&1 || die "jq is required for account imports"
command -v docker >/dev/null 2>&1 || die "Docker is required"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"

if [ -z "$source_url" ]; then
    source_url=$(env_value NUVIO_CLOUD_URL)
fi
if [ -z "$source_key" ]; then
    source_key=$(env_value NUVIO_CLOUD_PUBLISHABLE_KEY)
fi
[ -n "$source_url" ] || source_url=$DEFAULT_NUVIO_CLOUD_URL
[ -n "$source_key" ] || source_key=$DEFAULT_NUVIO_CLOUD_PUBLISHABLE_KEY

while [ "${source_url%/}" != "$source_url" ]; do
    source_url=${source_url%/}
done
validate_http_url "$source_url" "official backend URL"
case "$source_url" in
    https://*) ;;
    http://localhost|http://localhost:*|http://127.0.0.1|http://127.0.0.1:*) ;;
    *) die "official credentials require HTTPS (plain HTTP is allowed only for localhost testing)" ;;
esac
validate_header_token "$source_key" "official publishable key"

target_public_url=$(env_value SUPABASE_PUBLIC_URL)
while [ "${target_public_url%/}" != "$target_public_url" ]; do
    target_public_url=${target_public_url%/}
done
validate_http_url "$target_public_url" "SUPABASE_PUBLIC_URL"

local_anon_key=$(env_value ANON_KEY)
local_service_key=$(env_value SERVICE_ROLE_KEY)
validate_header_token "$local_anon_key" "local anonymous key"
validate_header_token "$local_service_key" "local service-role key"

kong_port=$(env_value KONG_HTTP_PORT)
case "$kong_port" in
    ""|*[!0-9]*) die "KONG_HTTP_PORT must be a port number" ;;
esac
local_api_url="http://127.0.0.1:$kong_port"

if [ -z "$account_email" ]; then
    printf 'Official Nuvio email: ' >&2
    IFS= read -r account_email || die "could not read the email"
fi
[ -n "$account_email" ] || die "email cannot be empty"
[ "${#account_email}" -le 320 ] || die "email is too long"
case "$account_email" in
    *@*) ;;
    *) die "email is invalid" ;;
esac

umask 077
import_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nuvio-account-import.XXXXXX")
terminal_echo_disabled=0
cleanup_import() {
    if [ "$terminal_echo_disabled" -eq 1 ]; then
        stty echo 2>/dev/null || true
    fi
    if [ -n "$import_tmp" ] && [ -d "$import_tmp" ]; then
        rm -f \
            "$import_tmp/curl.conf" \
            "$import_tmp/source-auth.json" \
            "$import_tmp/account-backup.json" \
            "$import_tmp/backup-rewritten.json" \
            "$import_tmp/storage-urls" \
            "$import_tmp/storage-object" \
            "$import_tmp/storage-response.json" \
            "$import_tmp/local-admin.json" \
            "$import_tmp/local-auth.json" \
            "$import_tmp/restore-response.json"
        rmdir "$import_tmp" 2>/dev/null || true
    fi
}
trap cleanup_import 0
trap 'exit 130' HUP INT TERM

read_account_password

email_json=$(printf '%s' "$account_email" | json_string)
password_json=$(printf '%s' "$account_password" | json_string)
auth_payload=$(printf '{"email":%s,"password":%s}' "$email_json" "$password_json")

echo "Authenticating with official Nuvio..."
status=$(printf '%s' "$auth_payload" | api_request \
    POST \
    "$source_url/auth/v1/token?grant_type=password" \
    "$source_key" \
    "" \
    "$import_tmp/source-auth.json")
case "$status" in
    200) ;;
    *) die "official Nuvio sign-in failed with HTTP $status: $(api_error "$import_tmp/source-auth.json")" ;;
esac

source_access_token=$(jq -er '.access_token | strings | select(length > 20)' "$import_tmp/source-auth.json") || \
    die "official Nuvio did not return an access token"
canonical_email=$(jq -er '.user.email | strings | select(length > 0)' "$import_tmp/source-auth.json") || \
    die "official Nuvio did not return the account email"
user_metadata_json=$(jq -c '
    .user.user_metadata // {} | if type == "object" then . else {} end
' "$import_tmp/source-auth.json")

echo "Exporting account data..."
status=$(printf '{}' | api_request \
    POST \
    "$source_url/rest/v1/rpc/sync_export_account_backup" \
    "$source_key" \
    "$source_access_token" \
    "$import_tmp/account-backup.json")
case "$status" in
    200) ;;
    *) die "official account export failed with HTTP $status: $(api_error "$import_tmp/account-backup.json")" ;;
esac

jq -e '
    .format == "nuvio_account_backup" and
    .version == 1 and
    (.data | type) == "object" and
    (.counts | type) == "object"
' "$import_tmp/account-backup.json" >/dev/null || die "official Nuvio returned an unsupported account backup"

echo "Account data found:"
jq -r '.counts | to_entries | sort_by(.key)[] | "  \(.key): \(.value)"' "$import_tmp/account-backup.json"
echo ""
echo "The local login will use the same email and password."
echo "Existing local app data for this email will be replaced."
echo "Sessions, MFA/passkeys, PIN hashes, tracker tokens, and provider credentials are not imported."

if [ "$assume_yes" -eq 0 ]; then
    [ -t 0 ] || die "confirmation requires a terminal; rerun with --yes after reviewing the backup counts"
    printf 'Continue with the import? [y/N] ' >&2
    IFS= read -r answer || answer=""
    case "$answer" in
        y|Y|yes|YES|Yes) ;;
        *) echo "Import cancelled."; exit 0 ;;
    esac
fi

db_name=$(env_value POSTGRES_DB)
local_user_id=$(docker compose exec -T db psql \
    --no-psqlrc \
    -U supabase_admin \
    -d "$db_name" \
    -v "account_email=$canonical_email" \
    -At <<'SQL'
SELECT id::text
FROM auth.users
WHERE lower(email) = lower(:'account_email')
ORDER BY created_at
LIMIT 1;
SQL
)

email_json=$(printf '%s' "$canonical_email" | json_string)
password_json=$(printf '%s' "$account_password" | json_string)
if [ -n "$local_user_id" ]; then
    case "$local_user_id" in
        *[!A-Fa-f0-9-]*) die "local Auth returned an invalid user ID" ;;
    esac
    admin_payload=$(printf '{"password":%s,"email_confirm":true,"user_metadata":%s}' \
        "$password_json" "$user_metadata_json")
    echo "Updating the existing local login..."
    status=$(printf '%s' "$admin_payload" | api_request \
        PUT \
        "$local_api_url/auth/v1/admin/users/$local_user_id" \
        "$local_service_key" \
        "$local_service_key" \
        "$import_tmp/local-admin.json")
    case "$status" in
        200) ;;
        *) die "local login update failed with HTTP $status: $(api_error "$import_tmp/local-admin.json")" ;;
    esac
else
    admin_payload=$(printf '{"email":%s,"password":%s,"email_confirm":true,"user_metadata":%s}' \
        "$email_json" "$password_json" "$user_metadata_json")
    echo "Creating the local login..."
    status=$(printf '%s' "$admin_payload" | api_request \
        POST \
        "$local_api_url/auth/v1/admin/users" \
        "$local_service_key" \
        "$local_service_key" \
        "$import_tmp/local-admin.json")
    case "$status" in
        200|201) ;;
        *) die "local login creation failed with HTTP $status: $(api_error "$import_tmp/local-admin.json")" ;;
    esac
fi

local_auth_payload=$(printf '{"email":%s,"password":%s}' "$email_json" "$password_json")
status=$(printf '%s' "$local_auth_payload" | api_request \
    POST \
    "$local_api_url/auth/v1/token?grant_type=password" \
    "$local_anon_key" \
    "" \
    "$import_tmp/local-auth.json")
case "$status" in
    200) ;;
    *) die "the recreated local login could not sign in with HTTP $status: $(api_error "$import_tmp/local-auth.json")" ;;
esac
local_access_token=$(jq -er '.access_token | strings | select(length > 20)' "$import_tmp/local-auth.json") || \
    die "local Auth did not return an access token"

copied_storage_count=0
if [ "$skip_storage" -eq 0 ]; then
    echo "Copying referenced official Storage objects..."
    copy_referenced_storage \
        "$import_tmp/account-backup.json" \
        "$source_url" \
        "$source_key" \
        "$target_public_url" \
        "$local_service_key" \
        "$local_api_url"
fi

echo "Restoring account data..."
status=$(jq -c '{p_backup: ., p_mode: "replace"}' "$import_tmp/account-backup.json" | api_request \
    POST \
    "$local_api_url/rest/v1/rpc/sync_restore_account_backup" \
    "$local_anon_key" \
    "$local_access_token" \
    "$import_tmp/restore-response.json")
case "$status" in
    200) ;;
    *) die "local account restore failed with HTTP $status: $(api_error "$import_tmp/restore-response.json")" ;;
esac

jq -e --slurpfile source "$import_tmp/account-backup.json" \
    '.counts == $source[0].counts' "$import_tmp/restore-response.json" >/dev/null || \
    die "local restore counts do not match the official backup"

account_password=""
password_json=""
auth_payload=""
admin_payload=""
local_auth_payload=""
user_metadata_json=""

echo ""
echo "Account import complete for $canonical_email."
echo "Referenced Storage objects copied: $copied_storage_count"
echo "Sign in to the self-hosted backend with the same email and password."
echo "Reconnect tracker/provider accounts and re-enroll MFA or passkeys as needed."
