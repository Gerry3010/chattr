#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Deploy des Android-Release-APKs als statische Datei auf geraldhofbauer.net
# (Craft-CMS-Volume "Statische Dateien") via craft-cms MCP-Server.
#
#   ./scripts/deploy-apk-homepage.sh [pfad/zum/apk]
#
# Default: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
# (arm64-only, ~56 MB — das fette Universal-APK sprengt das PHP-Memory-Limit
# des MCP-Endpoints beim Base64-Dekodieren; >200 MB Payload = HTTP 500.)
#
# Ablauf: alte app-release.apk-Assets (und Upload-Proben) löschen, damit der
# Dateiname/die URL stabil bleibt (Craft benennt bei Konflikt um), dann Upload.
# Ziel-URL: https://geraldhofbauer.net/static-files/app-release.apk
set -euo pipefail

APK="${1:-build/app/outputs/flutter-apk/app-arm64-v8a-release.apk}"
MCP_URL="https://geraldhofbauer.net/mcp/"
FOLDER_ID=4    # Root-Folder des Volumes "staticFiles"
ENTRY_ID=1048  # Craft-Entry "chattr-android" (Slug), Feld staticFile → /files/chattr-android

[ -f "$APK" ] || { echo "APK nicht gefunden: $APK" >&2; exit 1; }

# Bearer-Token aus der Claude-Code-Config (craft-cms MCP-Server) ziehen —
# Token gehört nicht ins Repo.
TOKEN=$(python3 - <<'PY'
import json, os
cfg = json.load(open(os.path.expanduser('~/.claude/settings.json')))
for a in cfg['mcpServers']['craft-cms']['args']:
    if a.startswith('Authorization: Bearer '):
        print(a.split('Bearer ', 1)[1]); break
PY
)
[ -n "$TOKEN" ] || { echo "Kein craft-cms-Token in ~/.claude/settings.json" >&2; exit 1; }

mcp_call() { # $1 = tool, $2 = args-json (via stdin bei -), sonst inline
  curl -sS -X POST "$MCP_URL" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    --data-binary "${2:-@-}"
}

echo "→ Alte Assets aufräumen (app-release.apk / mcp-upload-probe*) …"
OLD_IDS=$(mcp_call list_assets "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"list_assets\",\"arguments\":{\"volume\":\"staticFiles\",\"limit\":100}}}" \
  | python3 -c "
import json,sys
d=json.load(sys.stdin); assets=json.loads(d['result']['content'][0]['text'])['assets']
ids=[str(a['id']) for a in assets if a['filename'].startswith(('app-release','mcp-upload-probe'))]
print(' '.join(ids))")
for ID in $OLD_IDS; do
  echo "   delete asset $ID"
  mcp_call delete_asset "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"delete_asset\",\"arguments\":{\"id\":$ID}}}" >/dev/null
done

# Upload über tempFilePath: contentBase64 sprengt schon ab ~50 MB das
# PHP-Memory-Limit des Endpoints (base64-decode + JSON-Parse des Bodys).
# Also: Datei per scp auf den Server legen, ggf. in den Craft-Container
# kopieren, dann lädt Craft sie direkt vom Dateisystem.
# Deploy host kept OUT of the public repo. Set CHATTR_HOMEPAGE_SSH (or put it in
# scripts/.deploy-hosts.env, gitignored). See scripts/.deploy-hosts.env.example.
_DH="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/.deploy-hosts.env"; [ -f "$_DH" ] && . "$_DH"
SERVER="${CHATTR_HOMEPAGE_SSH:?set CHATTR_HOMEPAGE_SSH or scripts/.deploy-hosts.env}"
REMOTE_TMP="/tmp/app-release-upload.apk"

echo "→ scp $(du -h "$APK" | cut -f1) → $SERVER:$REMOTE_TMP …"
scp -q "$APK" "$SERVER:$REMOTE_TMP"
ssh "$SERVER" "chmod 644 $REMOTE_TMP"

try_upload() { # $1 = Pfad aus Sicht des Craft-PHP-Prozesses
  mcp_call upload_asset "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"upload_asset\",\"arguments\":{\"folderId\":$FOLDER_ID,\"filename\":\"app-release.apk\",\"tempFilePath\":\"$1\"}}}"
}

echo "→ Upload via tempFilePath ($REMOTE_TMP) …"
RESP=$(try_upload "$REMOTE_TMP")
echo "$RESP"
if echo "$RESP" | grep -q 'File not found'; then
  # PHP läuft offenbar im Container → Datei reinkopieren und nochmal.
  CONTAINER=$(ssh "$SERVER" "docker ps --format '{{.Names}}'" | grep -iE 'homepage|craft|php' | head -1)
  [ -n "$CONTAINER" ] || { echo "Kein Craft/PHP-Container gefunden — Layout prüfen." >&2; exit 1; }
  echo "→ docker cp in Container '$CONTAINER' …"
  ssh "$SERVER" "docker cp $REMOTE_TMP $CONTAINER:$REMOTE_TMP"
  RESP=$(try_upload "$REMOTE_TMP")
  echo "$RESP"
  ssh "$SERVER" "docker exec $CONTAINER rm -f $REMOTE_TMP" 2>/dev/null || true
fi
ssh "$SERVER" "rm -f $REMOTE_TMP"

# ── Download-SEITE selbstheilen ──────────────────────────────────────────────
# Der Upload oben hat das alte Asset gelöscht + ein neues mit NEUER ID angelegt →
# die Asset-Relation in Craft-Entry $ENTRY_ID (Feld staticFile) ist jetzt LEER, und
# https://geraldhofbauer.net/files/chattr-android zeigt "Keine Datei hochgeladen"
# (der direkte /static-files/-Link geht trotzdem). Also die Relation nachziehen.
# NUR staticFile — Titel/fileDescription sind versions-spezifischer, handkuratierter
# Text (inkl. evtl. "-fixed") und werden bewusst NICHT auto-überschrieben.
NEW_ID=$(echo "$RESP" | python3 -c "
import json,sys,re
raw=sys.stdin.read()
try:
    d=json.loads(re.search(r'\{.*\}',raw,re.S).group(0))
    print(json.loads(d['result']['content'][0]['text'])['id'])
except Exception:
    print('')" 2>/dev/null)

if [ -n "$NEW_ID" ]; then
  echo "→ Entry $ENTRY_ID nachziehen: staticFile = [$NEW_ID] (Download-Seite reparieren) …"
  mcp_call update_entry "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"update_entry\",\"arguments\":{\"id\":$ENTRY_ID,\"fields\":{\"staticFile\":[$NEW_ID]}}}}" >/dev/null
  mcp_call clear_caches "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"clear_caches\",\"arguments\":{}}}" >/dev/null 2>&1 || true
else
  echo "⚠  Konnte neue Asset-ID nicht aus der Upload-Antwort lesen — Entry $ENTRY_ID bitte manuell nachziehen (update_entry staticFile)." >&2
fi

echo
echo "→ Verifikation:"
curl -sSI https://geraldhofbauer.net/static-files/app-release.apk | grep -iE 'HTTP|content-length'
echo "   lokal:  $(stat -c%s "$APK") Bytes ($(sha256sum "$APK" | cut -c1-16)…)"
# Download-Seite: darf NICHT "Keine Datei" zeigen + muss den Download-Link enthalten.
PAGE=$(curl -sS https://geraldhofbauer.net/files/chattr-android 2>/dev/null || true)
if echo "$PAGE" | grep -qi "Keine Datei"; then
  echo "   ⚠  /files/chattr-android zeigt noch 'Keine Datei' — Relation prüfen!" >&2
elif echo "$PAGE" | grep -qi "static-files/app-release.apk"; then
  echo "   ✓ /files/chattr-android: Download-Link vorhanden"
fi
