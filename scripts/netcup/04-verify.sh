#!/usr/bin/env bash
# 04-verify.sh — post-cutover smoke checks. Run on the Netcup box (localhost) or
# from anywhere once DNS points at Netcup (pass BASE=https://api.chattr…).
set -uo pipefail

SUPA_DIR="${SUPA_DIR:-/home/chattr/app/supabase}"
BASE="${BASE:-http://127.0.0.1:${KONG_HTTP_PORT:-8000}}"

log() { printf '\n\033[1;35m▶ %s\033[0m\n' "$*"; }
cd "$SUPA_DIR" 2>/dev/null || true
ANON="$(grep -E '^ANON_KEY=' .env 2>/dev/null | cut -d= -f2- || true)"

log "Container-Status"
docker compose ps 2>/dev/null || true

log "Auth-Health ($BASE/auth/v1/health)"
curl -fsS -H "apikey: ${ANON}" "$BASE/auth/v1/health" && echo "  ✅ auth ok" || echo "  ❌ auth FAIL"

log "REST erreichbar ($BASE/rest/v1/)"
curl -fsS -o /dev/null -w "  HTTP %{http_code}\n" -H "apikey: ${ANON}" "$BASE/rest/v1/" || echo "  ❌ rest FAIL"

log "Realtime-Health"
curl -fsS -o /dev/null -w "  HTTP %{http_code}\n" -H "Authorization: Bearer ${ANON}" \
  "$BASE/realtime/v1/api/tenants/realtime-dev/health" || echo "  (evtl. anderer Pfad — Realtime im Log prüfen)"

log "Row-Counts (Vergleich mit Prod-Snapshot!)"
docker compose exec -T db psql -U postgres -tAc "
  SELECT 'profiles='||count(*) FROM profiles
  UNION ALL SELECT 'chats='||count(*) FROM chats
  UNION ALL SELECT 'chat_members='||count(*) FROM chat_members
  UNION ALL SELECT 'messages='||count(*) FROM messages
  UNION ALL SELECT 'device_tokens='||count(*) FROM device_tokens;" 2>/dev/null || echo "  (psql-Check übersprungen)"

log "Storage-Objekte im media-Bucket (Volume)"
find volumes/storage -type f 2>/dev/null | wc -l | sed 's/^/  Dateien: /'

cat <<EOF

Manuell noch prüfen (echter Client, z.B. Galaxy gegen die neue IP / Testbuild gegen chattr2):
  • Login/QR, Nachricht senden+empfangen (E2E), Media senden+abspielen, Push (FCM).
  • Vergleiche die Row-Counts oben mit dem Prod-Stand VOR dem Cutover.
EOF
