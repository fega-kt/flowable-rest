#!/usr/bin/env bash
# dev.sh — Fetch secrets từ Vault (dev path) và chạy local
#
# Secrets CHỈ tồn tại trong env của process này (export trực tiếp), KHÔNG ghi ra file .env
# trên đĩa — tránh lộ secret cho người khác đọc được trên máy dev.
#
# Hai chế độ:
#   bash dev.sh          → docker compose pull + up (chạy trong container)
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
  echo "[dev.sh] Vault trả về lỗi (HTTP $HTTP_CODE) khi đọc ${SECRET_PATH}:" >&2
  echo "$RESPONSE" >&2
  echo "[dev.sh] Kiểm tra lại: token còn hạn/đúng quyền đọc path này không." >&2
  exit 1
fi

if [ "$KV" -eq 2 ]; then
  DATA=$(echo "$RESPONSE" | jq -r '.data.data')
else
  DATA=$(echo "$RESPONSE" | jq -r '.data')
fi

# ── export secrets vào env của process này (không ghi file) ──────────────────

while IFS= read -r LINE; do
  LINE="${LINE//$'\r'/}"
  KEY="${LINE%%=*}"
  VALUE="${LINE#*=}"
  export "${KEY}=${VALUE}"
done < <(echo "$DATA" | jq -r 'to_entries[] | "\(.key)=\(.value)"')

echo "✔ Secrets loaded vào env (không ghi ra .env)"

# Vault lưu Supabase DB theo HOST/PORT/NAME riêng lẻ — ghép lại thành JDBC URL nếu chưa có sẵn
if [ -z "${SUPABASE_DB_URL:-}" ] && [ -n "${SUPABASE_DB_HOST:-}" ] && [ -n "${SUPABASE_DB_NAME:-}" ]; then
  export SUPABASE_DB_URL="jdbc:postgresql://${SUPABASE_DB_HOST}:${SUPABASE_DB_PORT:-5432}/${SUPABASE_DB_NAME}?sslmode=require"
fi

# ── log các key đã load (che giá trị, không in secret ra terminal) ───────────

mask_value() {
  local v="$1" len
  len=${#v}
  if [ "$len" -le 4 ]; then
    printf '****'
  else
    printf '%s%s%s' "${v:0:2}" "$(printf '%*s' $((len - 4)) '' | tr ' ' '*')" "${v: -2}"
  fi
}

CYAN='\033[0;36m'
YELLOW='\033[0;33m'
DIM='\033[2m'
RESET='\033[0m'

printf "${CYAN}▶ Các biến đã load (giá trị đã che bớt):${RESET}\n"
while IFS= read -r KEY; do
  KEY="${KEY//$'\r'/}"
  [ -n "$KEY" ] || continue
  printf "    ${YELLOW}%s${RESET}=${DIM}%s${RESET}\n" "$KEY" "$(mask_value "${!KEY}")"
done < <(echo "$DATA" | jq -r 'keys[]')
if [ -n "${SUPABASE_DB_URL:-}" ]; then
  printf "    ${YELLOW}%s${RESET}=${DIM}%s${RESET} (tự ghép từ HOST/PORT/NAME)\n" "SUPABASE_DB_URL" "$(mask_value "$SUPABASE_DB_URL")"
fi

# ── run ───────────────────────────────────────────────────────────────────────

# Tô đậm số port trong log Tomcat/Spring Boot ("... on port 8080 ...") cho dễ thấy
ESC=$'\033'
highlight_port() {
  sed -u -E "s/(on port )([0-9]+)/\1${ESC}[1;32m\2${ESC}[0m/"
}

if [ "$MODE" = "mvn" ]; then
  # pom.xml yêu cầu Java 17 — Lombok pin theo Spring Boot 3.2 parent chưa hỗ trợ JDK mới hơn
  # (annotation processor không sinh field `log` từ @Slf4j trên JDK 25). Ép dùng JDK 17 nếu có.
  for JDK17_CANDIDATE in "/c/Program Files/Eclipse Adoptium/"jdk-17*; do
    if [ -d "$JDK17_CANDIDATE" ]; then
      export JAVA_HOME="$JDK17_CANDIDATE"
      export PATH="$JAVA_HOME/bin:$PATH"
      break
    fi
  done

  echo "▶ Chạy mvn spring-boot:run (JAVA_HOME=${JAVA_HOME:-mặc định hệ thống}) ..."

  # Map tên biến Vault → Spring datasource properties
  export SPRING_DATASOURCE_URL="$SUPABASE_DB_URL"
  export SPRING_DATASOURCE_USERNAME="$SUPABASE_DB_USER"
  export SPRING_DATASOURCE_PASSWORD="$SUPABASE_DB_PASSWORD"

  cd flowable-server
  mvn spring-boot:run 2>&1 | highlight_port
else
  echo "▶ docker compose pull + up (dùng image production từ GHCR) ..."
  docker compose pull
  docker compose up 2>&1 | highlight_port
fi
