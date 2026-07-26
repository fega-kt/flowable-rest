#!/usr/bin/env bash
# up.sh — Fetch secrets từ Vault rồi deploy Flowable server
#
# Hai chế độ:
#   bash up.sh                        → interactive (đọc .vault.json, hỏi login method)
#   CI (VAULT_TOKEN + VAULT_ADDR + VAULT_SECRET_PATH đã set trong env) → non-interactive, dùng cho GitHub Actions
#
# Nếu APP_IMAGE được set (CI build & push lên GHCR) → pull image đó thay vì build tại chỗ.
set -euo pipefail
cd "$(dirname "$0")"

if [ -n "${VAULT_TOKEN:-}" ] && [ -n "${VAULT_ADDR:-}" ] && [ -n "${VAULT_SECRET_PATH:-}" ]; then
  echo "▶ CI mode: dùng VAULT_TOKEN/VAULT_ADDR/VAULT_SECRET_PATH từ environment"
  SECRET_PATH="$VAULT_SECRET_PATH"
  KV="${VAULT_KV:-2}"
else
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
      VAULT_TOKEN=$(curl -sSf "${VAULT_ADDR}/v1/auth/userpass/login/${USERNAME}" \
        -d "{\"password\":\"${PASSWORD}\"}" | jq -r '.auth.client_token')
      ;;
    LDAP)
      read -rp  "? LDAP username: " USERNAME
      read -rsp "? LDAP password: " PASSWORD; echo
      VAULT_TOKEN=$(curl -sSf "${VAULT_ADDR}/v1/auth/ldap/login/${USERNAME}" \
        -d "{\"password\":\"${PASSWORD}\"}" | jq -r '.auth.client_token')
      ;;
  esac
fi

# ── fetch secrets ─────────────────────────────────────────────────────────────

MOUNT=$(echo "$SECRET_PATH" | cut -d/ -f1)
REST=$(echo "$SECRET_PATH"  | cut -d/ -f2-)
if [ "$KV" -eq 2 ]; then
  API_PATH="${MOUNT}/data/${REST}"
else
  API_PATH="${SECRET_PATH}"
fi

HTTP_RESPONSE=$(curl -sS -w '\n%{http_code}' "${VAULT_ADDR}/v1/${API_PATH}" \
  -H "X-Vault-Token: ${VAULT_TOKEN}")
HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)
RESPONSE=$(echo "$HTTP_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
  echo "[up.sh] Vault trả về lỗi (HTTP $HTTP_CODE) khi đọc ${SECRET_PATH}:" >&2
  echo "$RESPONSE" >&2
  echo "[up.sh] Kiểm tra lại: token còn hạn/đúng quyền đọc path này không." >&2
  exit 1
fi

if [ "$KV" -eq 2 ]; then
  DATA=$(echo "$RESPONSE" | jq -r '.data.data')
else
  DATA=$(echo "$RESPONSE" | jq -r '.data')
fi

# ── write .env ────────────────────────────────────────────────────────────────

echo "$DATA" | jq -r 'to_entries[] | "\(.key)=\(.value)"' | tr -d '\r' > .env
echo "✔ Secrets written to .env"

if [ -n "${APP_IMAGE:-}" ]; then
  echo "APP_IMAGE=${APP_IMAGE}" >> .env
fi

# ── log các key đã ghi vào .env (che giá trị, không in secret ra terminal/CI log) ─

mask_value() {
  local v="$1" len
  len=${#v}
  if [ "$len" -le 4 ]; then
    printf '****'
  else
    printf '%s%s%s' "${v:0:2}" "$(printf '%*s' $((len - 4)) '' | tr ' ' '*')" "${v: -2}"
  fi
}

echo "▶ Các biến đã ghi vào .env (giá trị đã che bớt):"
while IFS='=' read -r KEY VALUE; do
  [ -n "$KEY" ] || continue
  printf '    %s=%s\n' "$KEY" "$(mask_value "$VALUE")"
done < .env

# ── pull & deploy ─────────────────────────────────────────────────────────────

# Chỉ định -f rõ ràng để production KHÔNG merge docker-compose.override.yml
# docker-compose.yml không còn build config — luôn pull image từ GHCR (mặc định :latest, override qua APP_IMAGE)
echo "▶ Pulling image ${APP_IMAGE:-ghcr.io/fega-kt/flowable-rest-flowable-server:latest} ..."
docker compose -f docker-compose.yml pull
docker compose -f docker-compose.yml up -d
