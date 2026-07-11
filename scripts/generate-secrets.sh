#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

[ -f .env ] || { echo "Error: .env does not exist" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "Error: openssl is required" >&2; exit 1; }

base64_url_encode() {
    openssl enc -base64 -A | tr '+/' '-_' | tr -d '='
}

set_env() {
    key=$1
    value=$2
    temp_env=$(mktemp ./.env.tmp.XXXXXX)
    found=0

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$key="*)
                printf '%s=%s\n' "$key" "$value"
                found=1
                ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < .env > "$temp_env"

    if [ "$found" -eq 0 ]; then
        printf '%s=%s\n' "$key" "$value" >> "$temp_env"
    fi

    chmod 600 "$temp_env"
    mv "$temp_env" .env
}

jwt_secret=$(openssl rand -hex 32)
header=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | base64_url_encode)
issued_at=$(date +%s)
expires_at=$((issued_at + 5 * 365 * 24 * 60 * 60))

sign_token() {
    role=$1
    payload=$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' "$role" "$issued_at" "$expires_at" | base64_url_encode)
    content="${header}.${payload}"
    signature=$(printf '%s' "$content" | openssl dgst -binary -sha256 -hmac "$jwt_secret" | base64_url_encode)
    printf '%s.%s' "$content" "$signature"
}

set_env POSTGRES_PASSWORD "$(openssl rand -hex 24)"
set_env JWT_SECRET "$jwt_secret"
set_env ANON_KEY "$(sign_token anon)"
set_env SERVICE_ROLE_KEY "$(sign_token service_role)"
set_env DASHBOARD_PASSWORD "$(openssl rand -hex 20)"
set_env SECRET_KEY_BASE "$(openssl rand -hex 48)"
set_env VAULT_ENC_KEY "$(openssl rand -hex 16)"
set_env PG_META_CRYPTO_KEY "$(openssl rand -hex 32)"
set_env S3_PROTOCOL_ACCESS_KEY_ID "$(openssl rand -hex 16)"
set_env S3_PROTOCOL_ACCESS_KEY_SECRET "$(openssl rand -hex 32)"
set_env POOLER_TENANT_ID "$(openssl rand -hex 8)"

chmod 600 .env
echo "Generated deployment secrets in .env"
