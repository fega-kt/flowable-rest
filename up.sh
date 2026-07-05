#!/usr/bin/env bash
# up.sh — Fetch secrets từ Vault rồi deploy Flowable server
# Dùng: bash up.sh
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .vault.json ]; then
  echo "Error: .vault.json not found. Copy .vault.json.example và điền giá trị thật." >&2
  exit 1
fi

VAULT_ADDR=$(jq -r '.addr // empty' .vault.json)
SECRET_PATH=$(jq -r '.envs.production // empty' .vault.json)
KV=$(jq -r '.kv // 2' .vault.json)

if [ -z "$VAULT_ADDR" ]; then
  echo '[up.sh] Thiếu "addr" trong .vault.json.' >&2
  exit 1
fi
if [ -z "$SECRET_PATH" ]; then
  echo '[up.sh] Thiếu "envs.production" trong .vault.json.' >&2
  exit 1
fi

# ── auth method ──────────────────────────────────────────────────────────────

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

# ── write .env ────────────────────────────────────────────────────────────────

echo "$DATA" | jq -r 'to_entries[] | "\(.key)=\(.value)"' > .env
echo "✔ Secrets written to .env"

# ── build & deploy ────────────────────────────────────────────────────────────

# Chỉ định -f rõ ràng để production KHÔNG merge docker-compose.override.yml
docker compose -f docker-compose.yml build
docker compose -f docker-compose.yml up -d
