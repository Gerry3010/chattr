#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Switches the web app's CSP from REPORT to ARMED — and back again.
#
# sudo bash ~/csp-enforce.sh # armed sudo bash ~/csp-enforce.sh --zurueck # back
# to report
#
# ONLY the header's name is swapped, never its value. That makes the way back
# exactly the same way backwards, and nobody has to assemble a policy by hand in
# an emergency.
#
# WHAT CAN GO WRONG: if a source is missing, the browser blocks it — and Flutter
# then shows not an error but a WHITE SCREEN. The report run on 2026-08-21
# showed zero violations, but the paths that would violate did not occur in it:
# the chat list that was tested contained not one real profile picture and no
# link preview. `img-src … https:` and `media-src` are therefore DERIVED, not
# measured. If images are missing after arming, that is the first place to look
# — and `--zurueck` is one call away.
set -euo pipefail

CADDYFILE=/etc/caddy/Caddyfile
STAMP=$(date +%Y%m%d-%H%M%S)
SICHERUNG="$CADDYFILE.bak-cspmode-$STAMP"

MODUS="${1:-scharf}"
if [ "$MODUS" = "--zurueck" ]; then
  VON="Content-Security-Policy"; NACH="Content-Security-Policy-Report-Only"
  WAS="zurueck auf BERICHT"
else
  VON="Content-Security-Policy-Report-Only"; NACH="Content-Security-Policy"
  WAS="auf SCHARF"
fi

[ -f "$CADDYFILE" ] || { echo "FEHLER: $CADDYFILE fehlt — laeuft das hier auf nc-chattr?"; exit 1; }

# Narrow it to the line in the right site block: `header <FROM> "…"`. The prefix
# comparison would otherwise be ambiguous — "Content-Security-Policy" is a
# prefix of "Content-Security-Policy-Report-Only".
if ! grep -q "header ${VON} \"" "$CADDYFILE"; then
  echo "Keine Zeile 'header ${VON}' gefunden — schon ${WAS}? Nichts zu tun."
  exit 0
fi

cp -a "$CADDYFILE" "$SICHERUNG"
echo "Sicherung: $SICHERUNG"

sed -i "s|header ${VON} \"|header ${NACH} \"|" "$CADDYFILE"
echo "umgestellt: ${WAS}"

ENVFILE=/etc/caddy/cloudflare.env
[ -r "$ENVFILE" ] && { set -a; . "$ENVFILE"; set +a; }

echo "--- caddy validate ---"
if ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
  caddy validate --config "$CADDYFILE" --adapter caddyfile 2>&1 | tail -3
  echo "UNGUELTIG — Sicherung wird zurueckgespielt."
  cp -a "$SICHERUNG" "$CADDYFILE"; exit 1
fi
echo "   Konfiguration ok."

if ! systemctl reload caddy; then
  echo "RELOAD FEHLGESCHLAGEN — alter Stand laeuft weiter, Datei wird zurueckgesetzt."
  cp -a "$SICHERUNG" "$CADDYFILE"; systemctl reload caddy || true; exit 1
fi

echo "--- neu geladen. Nachweis von aussen: ---"
sleep 2
curl -sI --max-time 15 https://app.chattr.geraldhofbauer.net \
  | grep -i "^content-security-policy" | cut -c1-60 | sed 's/^/   /'

if [ "$MODUS" != "--zurueck" ]; then
  echo
  echo "  Falls Bilder oder Vorschauen fehlen:"
  echo "      sudo bash ~/csp-enforce.sh --zurueck"
fi
