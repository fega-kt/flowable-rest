#!/usr/bin/env bash
# dev.sh — Fetch secrets từ Vault (dev path) và chạy local
#
# Hai chế độ:
#   bash dev.sh          → docker compose build + up (chạy trong container)
#   bash dev.sh --mvn    → export env vars rồi chạy mvn spring-boot:run (hot reload)
set -euo pipefail
cd "$(dirname "$0")"

MODE="compose"
if [[ "${1:-}" == "--mvn" ]]; then
  MODE="mvn"
fi

if [ ! -f .vault.json ]; then
  echo "Error: .vault.json not found. Copy .vault.json.example và điền giá trị thật." >&2
  exit 1
fi

VAULT_ADDR=$(jq -r '.addr // empty' .vault.json)
SECRET_PATH=$(jq -r '.envs.dev // empty' .vault.json)
KV=$(jq -r '.kv // 2' .vault.json)

if [ -z "$VAULT_ADDR" ] || [ -z "$SECRET_PATH" ]; then
  echo '[dev.sh] Thiếu addr hoặc envs.dev trong .vault.json.' >&2
  exit 1
fi

# ── auth ─────────────────────────────────────────────────────────────────────

echo ""
echo "? Which login method?"
PS3="> "
select METHOD in "Token" "Userpass" "LDAP"; do
  [ -n "$METHOD" ] && break
done

case $METHOD in
  Token)
    read -rsp "? Vault token: " VAULT_TOKEN; echo
    ;;
  Userpass)
    read -rp  "? Username: "   USERNAME
    read -rsp "? Password: "   PASSWORD; echo
    VAULT_TOKEN=$(curl -sf "${VAULT_ADDR}/v1/auth/userpass/login/${USERNAME}" \
      -d "{\"password\":\"${PASSWORD}\"}" | jq -r '.auth.client_token')
    ;;
  LDAP)
    read -rp  "? LDAP username: " USERNAME
    read -rsp "? LDAP password: " PASSWORD; echo
    VAULT_TOKEN=$(curl -sf "${VAULT_ADDR}/v1/auth/ldap/login/${USERNAME}" \
      -d "{\"password\":\"${PASSWORD}\"}" | jq -r '.auth.client_token')
    ;;
esac

# ── fetch secrets ─────────────────────────────────────────────────────────────

MOUNT=$(echo "$SECRET_PATH" | cut -d/ -f1)
REST=$(echo "$SECRET_PATH"  | cut -d/ -f2-)
if [ "$KV" -eq 2 ]; then
  API_PATH="${MOUNT}/data/${REST}"
else
  API_PATH="${SECRET_PATH}"
fi

RESPONSE=$(curl -sf "${VAULT_ADDR}/v1/${API_PATH}" \
  -H "X-Vault-Token: ${VAULT_TOKEN}")

if [ "$KV" -eq 2 ]; then
  DATA=$(echo "$RESPONSE" | jq -r '.data.data')
else
  DATA=$(echo "$RESPONSE" | jq -r '.data')
fi

echo "$DATA" | jq -r 'to_entries[] | "\(.key)=\(.value)"' > .env
echo "✔ Secrets written to .env"

# ── run ───────────────────────────────────────────────────────────────────────

if [ "$MODE" = "mvn" ]; then
  echo "▶ Exporting env vars và chạy mvn spring-boot:run ..."
  # shellcheck disable=SC2046
  export $(grep -v '^#' .env | xargs)

  # Map tên biến Vault → Spring datasource properties
  export SPRING_DATASOURCE_URL="$SUPABASE_DB_URL"
  export SPRING_DATASOURCE_USERNAME="$SUPABASE_DB_USER"
  export SPRING_DATASOURCE_PASSWORD="$SUPABASE_DB_PASSWORD"

  cd flowable-server
  mvn spring-boot:run
else
  echo "▶ docker compose pull + up (dùng image production từ GHCR) ..."
  docker compose pull
  docker compose up
fi
