#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Install the EU-without-France geo gate for chattr.at on nc-chattr.
#
# Run ON THE BOX as root:
#     sudo bash apply-chattr-at-geoblock.sh
#
# What it does: installs the 451 page, swaps the `chattr.at` site block in
# /etc/caddy/Caddyfile for the one in this repo, reloads Caddy, then proves the
# gate works by asking the origin directly with a faked country header.
#
# Safe to re-run. The old Caddyfile is kept as a timestamped backup, and a
# reload that fails validation leaves the RUNNING config untouched — Caddy only
# swaps in a new config once it parses.

set -euo pipefail

CADDYFILE=/etc/caddy/Caddyfile
PAGE_DIR=/etc/caddy/geoblock
SITE_BLOCK_SRC="$(dirname "$0")/caddy/chattr.at.Caddyfile"
PAGE_SRC="$(dirname "$0")/caddy/geoblock/451.html"

[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausführen." >&2; exit 1; }
[[ -f $SITE_BLOCK_SRC ]] || { echo "Nicht gefunden: $SITE_BLOCK_SRC" >&2; exit 1; }
[[ -f $PAGE_SRC ]]       || { echo "Nicht gefunden: $PAGE_SRC" >&2; exit 1; }
[[ -f $CADDYFILE ]]      || { echo "Nicht gefunden: $CADDYFILE" >&2; exit 1; }

BACKUP="$CADDYFILE.bak-$(date +%Y%m%d-%H%M%S)"
cp -a "$CADDYFILE" "$BACKUP"
echo "Backup: $BACKUP"

install -d -m 755 "$PAGE_DIR"
install -m 644 "$PAGE_SRC" "$PAGE_DIR/451.html"
echo "Sperrseite: $PAGE_DIR/451.html"

# Replace the chattr.at site block by brace matching rather than line numbers —
# the block moves whenever another site is added above it.
python3 - "$CADDYFILE" "$SITE_BLOCK_SRC" <<'PY'
import re, sys

caddyfile, src = sys.argv[1], sys.argv[2]
current = open(caddyfile).read()

# The replacement is everything from the site address line onwards (the repo
# file's header comments stay in the repo, not in /etc/caddy).
block = open(src).read()
start = block.index('chattr.at, www.chattr.at {')
block = block[start:].rstrip() + '\n'

m = re.search(r'^chattr\.at, www\.chattr\.at \{', current, re.M)
if not m:
    sys.exit('chattr.at-Block nicht in %s gefunden — nichts geändert.' % caddyfile)

# Walk braces from the opening one so a nested block can't end the match early.
i = current.index('{', m.start())
depth = 0
for j in range(i, len(current)):
    if current[j] == '{':
        depth += 1
    elif current[j] == '}':
        depth -= 1
        if depth == 0:
            end = j + 1
            break
else:
    sys.exit('Unbalancierte Klammern im chattr.at-Block — nichts geändert.')

open(caddyfile, 'w').write(current[:m.start()] + block.rstrip('\n') + current[end:])
print('chattr.at-Block ersetzt.')
PY

# Best-effort syntax check. A bare `caddy validate` trips over the Cloudflare
# DNS sites, whose CF_API_TOKEN only exists in the systemd unit's environment —
# a dummy value gets it past the placeholder without ever being used.
if ! CF_API_TOKEN=dummy caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
  echo "Hinweis: 'caddy validate' meldet etwas (oft nur das CF-Token). Reload entscheidet."
fi

systemctl reload caddy
sleep 1
systemctl is-active --quiet caddy || {
  echo "Caddy läuft nicht mehr — Backup zurückspielen:" >&2
  echo "  sudo cp -a $BACKUP $CADDYFILE && sudo systemctl reload caddy" >&2
  exit 1
}

echo
echo "--- Prüfung direkt am Origin (Cloudflare umgangen, Land gefälscht) ---"
probe() {
  local country=$1 path=$2 want=$3
  local code
  code=$(curl -sk -o /dev/null -w '%{http_code}' \
           --resolve "chattr.at:443:127.0.0.1" \
           -H "CF-IPCountry: $country" "https://chattr.at$path")
  printf '  %-3s %-38s -> %s %s\n' "$country" "$path" "$code" \
    "$([[ $code == "$want" ]] && echo OK || echo "ERWARTET $want")"
}
probe AT /                                      200
probe DE /                                      200
probe FR /                                      451
probe US /                                      451
probe FR /api/updates/android/manifest.json     200
probe US /api/updates/android/manifest.json     200
probe US /download/latest                       451

echo
echo "Fertig. Rückbau jederzeit: sudo cp -a $BACKUP $CADDYFILE && sudo systemctl reload caddy"
