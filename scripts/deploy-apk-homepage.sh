#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Deploys the Android release APK as a static file to geraldhofbauer.net (Craft
# CMS volume "static files") via the craft-cms MCP server.
#
# ./scripts/deploy-apk-homepage.sh [path/to/apk]
#
# Default: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk (arm64 only,
# ~56 MB — the fat universal APK blows the PHP memory limit of the MCP endpoint
# while base64-decoding; >200 MB payload = HTTP 500.)
#
# Procedure: delete the old app-release.apk assets (and upload leftovers) so the
# file name/URL stays stable (Craft renames on a conflict), then upload. Target
# URL: https://geraldhofbauer.net/static-files/app-release.apk
set -euo pipefail

APK="${1:-build/app/outputs/flutter-apk/app-arm64-v8a-release.apk}"
MCP_URL="https://geraldhofbauer.net/mcp/"
FOLDER_ID=4    # Root-Folder des Volumes "staticFiles"
ENTRY_ID=1048  # Craft-Entry "chattr-android" (Slug), Feld staticFile → /files/chattr-android

[ -f "$APK" ] || { echo "APK nicht gefunden: $APK" >&2; exit 1; }

# Pull the bearer token from the Claude Code config (craft-cms MCP server) — the
# token does not belong in the repo.
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

# Upload via tempFilePath: contentBase64 blows the endpoint's PHP memory limit
# from around 50 MB on (base64 decode + JSON parse of the body). So: put the
# file on the server via scp, copy it into the Craft container if need be, and
# Craft then loads it straight from the file system. Deploy host kept OUT of the
# public repo. Set CHATTR_HOMEPAGE_SSH (or put it in scripts/.deploy-hosts.env,
# gitignored). See scripts/.deploy-hosts.env.example.
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
  # PHP is evidently running in the container → copy the file in and try again.
  CONTAINER=$(ssh "$SERVER" "docker ps --format '{{.Names}}'" | grep -iE 'homepage|craft|php' | head -1)
  [ -n "$CONTAINER" ] || { echo "Kein Craft/PHP-Container gefunden — Layout prüfen." >&2; exit 1; }
  echo "→ docker cp in Container '$CONTAINER' …"
  ssh "$SERVER" "docker cp $REMOTE_TMP $CONTAINER:$REMOTE_TMP"
  RESP=$(try_upload "$REMOTE_TMP")
  echo "$RESP"
  ssh "$SERVER" "docker exec $CONTAINER rm -f $REMOTE_TMP" 2>/dev/null || true
fi
ssh "$SERVER" "rm -f $REMOTE_TMP"

# ── Self-heal the download PAGE ─────────────────────────────────────────────
# The upload above deleted the old asset and created a new one with a NEW ID →
# the asset relation in Craft entry $ENTRY_ID (field staticFile) is now EMPTY,
# and https://geraldhofbauer.net/files/chattr-android shows "no file uploaded"
# (the direct /static-files/ link still works). So update the relation. ONLY
# staticFile — title and fileDescription are version-specific, hand-curated text
# (including a possible "-fixed") and are deliberately NOT overwritten
# automatically.
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
# The download page: must NOT show "no file" and must contain the download link.
PAGE=$(curl -sS https://geraldhofbauer.net/files/chattr-android 2>/dev/null || true)
if echo "$PAGE" | grep -qi "Keine Datei"; then
  echo "   ⚠  /files/chattr-android zeigt noch 'Keine Datei' — Relation prüfen!" >&2
elif echo "$PAGE" | grep -qi "static-files/app-release.apk"; then
  echo "   ✓ /files/chattr-android: Download-Link vorhanden"
fi
