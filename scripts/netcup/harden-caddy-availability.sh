#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Make the reverse proxy survive its own death, and close the hole that let a
# non-root user kill it.
#
# Run ON THE BOX as root:
#     sudo bash harden-caddy-availability.sh
#
# ---------------------------------------------------------------------------
# Why (2026-08-04 outage, >30 min: backend, chattr.at and the APK downloads)
# ---------------------------------------------------------------------------
# Two independent defects lined up.
#
# 1. `Restart=no` on caddy.service. NOT on-failure, not on-abnormal — no.
#    Whatever ends the process (crash, OOM kill, a reload that fails to load a
#    config, an admin-API stop) leaves the whole box's HTTP dark until a human
#    notices. Every service behind that proxy was healthy the entire time.
#
# 2. The admin API listened on localhost:2019, answering ANY local user. That
#    is how the outage actually started: a `caddy stop` meant for a throwaway
#    test instance found no admin address in its own config (it had `admin
#    off`), fell back to the default port, and stopped the production server
#    instead. The test instance kept running. `systemctl status` then showed
#    `inactive (dead) … status=0/SUCCESS`, which reads like a planned shutdown.
#
# What this changes:
#   * Restart=always + RestartSec=5s      → a dead proxy comes back by itself.
#   * StartLimit 5 tries / 60s            → a genuinely broken config fails
#                                           loudly instead of restart-looping.
#   * admin on a unix socket in /run/caddy (RuntimeDirectoryMode 0750, owner
#     caddy:caddy, and `gerry` is not in that group) → no unprivileged process
#     can reach the admin API at all. The footgun is gone, not documented.
#   * ExecReload targets that socket, so `systemctl reload caddy` keeps working.
#
# Deliberately NOT added: a cron that force-starts Caddy. Restart=always already
# covers every crash, and a force-start loop would fight you the moment you stop
# the service on purpose for maintenance. The case Restart=always cannot fix —
# systemd giving up on a broken config — needs a human, not another restart.
#
# Everything is verified after the fact and rolled back automatically if the
# service does not come up clean.

set -euo pipefail

DROPIN_DIR=/etc/systemd/system/caddy.service.d
DROPIN="$DROPIN_DIR/override.conf"
CADDYFILE=/etc/caddy/Caddyfile
SOCKET=/run/caddy/admin.sock
STAMP=$(date +%Y%m%d-%H%M%S)

[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausführen." >&2; exit 1; }
[[ -f $DROPIN ]]  || { echo "Nicht gefunden: $DROPIN" >&2; exit 1; }
[[ -f $CADDYFILE ]] || { echo "Nicht gefunden: $CADDYFILE" >&2; exit 1; }

BACKUP_DROPIN="$DROPIN.bak-$STAMP"
BACKUP_CADDY="$CADDYFILE.bak-$STAMP"
cp -a "$DROPIN" "$BACKUP_DROPIN"
cp -a "$CADDYFILE" "$BACKUP_CADDY"
echo "Backups: $BACKUP_DROPIN"
echo "         $BACKUP_CADDY"

rollback() {
  echo
  echo "!! Fehlgeschlagen — spiele Backups zurück und starte den alten Stand." >&2
  cp -a "$BACKUP_DROPIN" "$DROPIN"
  cp -a "$BACKUP_CADDY" "$CADDYFILE"
  systemctl daemon-reload
  systemctl restart caddy || true
  sleep 2
  systemctl is-active --quiet caddy \
    && echo "Alter Stand läuft wieder." >&2 \
    || echo "ACHTUNG: Caddy läuft NICHT. Von Hand prüfen: journalctl -u caddy -n 50" >&2
  exit 1
}

# --- 1. systemd drop-in -----------------------------------------------------
# The EnvironmentFile line is load-bearing (CF_API_TOKEN for the DNS-01 sites)
# and is carried over from the existing file rather than retyped.
ENVFILE_LINE=$(grep -E '^EnvironmentFile=' "$DROPIN" || true)
[[ -n $ENVFILE_LINE ]] || { echo "EnvironmentFile-Zeile fehlt im Drop-in — abgebrochen." >&2; exit 1; }

cat > "$DROPIN" <<EOF
[Unit]
# A broken config should fail loudly after a few tries, not restart forever.
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
$ENVFILE_LINE

# Come back from any exit — crash, OOM, or an admin-API stop. A deliberate
# \`systemctl stop\` is still respected; systemd does not fight that.
Restart=always
RestartSec=5s

# Private admin socket instead of localhost:2019. 0750 + caddy:caddy means no
# unprivileged local process can talk to the admin API.
RuntimeDirectory=caddy
RuntimeDirectoryMode=0750

# Reload has to be told where the socket is now.
ExecReload=
ExecReload=/usr/bin/caddy reload --config $CADDYFILE --force --address unix/$SOCKET
EOF
echo "Drop-in geschrieben."

# --- 2. Caddyfile global options -------------------------------------------
# The "is there already an admin directive?" test has to look ONLY inside the
# global options block. A first version grepped the whole file for `^\s*admin\s`
# and matched `basic_auth { admin <hash> }` in the admin.chattr site — so it
# reported "already configured" and silently skipped the change. Guard and
# insertion now share one parse of the same block.
python3 - "$CADDYFILE" "$SOCKET" <<'PY'
import sys
path, socket = sys.argv[1], sys.argv[2]
src = open(path).read()
if not src.lstrip().startswith('{'):
    sys.exit('Kein globaler Options-Block am Dateianfang — nichts geändert.')

open_i = src.index('{')
depth = 0
for j in range(open_i, len(src)):
    if src[j] == '{':
        depth += 1
    elif src[j] == '}':
        depth -= 1
        if depth == 0:
            close_i = j
            break
else:
    sys.exit('Globaler Options-Block ist nicht geschlossen — nichts geändert.')

globals_block = src[open_i + 1:close_i]
if any(line.strip().startswith('admin ') for line in globals_block.splitlines()):
    print('Globale admin-Direktive existiert bereits — unangetastet.')
else:
    src = src[:open_i + 1] + f'\n\tadmin unix/{socket}' + src[open_i + 1:]
    open(path, 'w').write(src)
    print('admin-Socket in die globalen Optionen eingetragen.')
PY

# --- 3. Anwenden ------------------------------------------------------------
systemctl daemon-reload
# A restart, not a reload: the admin listener itself is what changes.
systemctl restart caddy || rollback
sleep 3
systemctl is-active --quiet caddy || rollback

# --- 4. Nachweis ------------------------------------------------------------
echo
echo "--- Prüfung ---"
ok=0
check() { # beschreibung, erwartet, ist
  if [[ "$2" == "$3" ]]; then printf '  ✓ %-46s %s\n' "$1" "$3"
  else printf '  ✗ %-46s %s (erwartet %s)\n' "$1" "$3" "$2"; ok=1; fi
}

check "Restart-Politik" "always" "$(systemctl show caddy -p Restart --value)"
# `|| true` instead of `|| echo 000`: on a connection error curl itself already
# writes "000" to stdout and ADDITIONALLY returns an error code — an echo in the
# || branch appended a second one and turned the success case into "000000", so
# a reported failure in a perfectly correct state.
check "Admin-Port 2019 tot (war der Fußangel)" "000" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://localhost:2019/config/ || true)"
[[ -S $SOCKET ]] && printf '  ✓ %-46s %s\n' "Admin-Socket vorhanden" "$SOCKET" \
                 || { printf '  ✗ %-46s fehlt\n' "Admin-Socket"; ok=1; }
check "Sites antworten (chattr.at über Origin)" "200" \
  "$(curl -sk -o /dev/null -w '%{http_code}' --resolve chattr.at:443:127.0.0.1 \
       -H 'CF-IPCountry: AT' https://chattr.at/ || true)"

# Moving the socket is exactly the change that can break `systemctl reload`
# (ExecReload has to know the new address), and apply-chattr-at-geoblock.sh
# hangs on it. So actually run it once here rather than hope.
if systemctl reload caddy 2>/dev/null && sleep 1 && systemctl is-active --quiet caddy; then
  printf '  ✓ %-46s %s\n' "systemctl reload caddy" "ok"
else
  printf '  ✗ %-46s %s\n' "systemctl reload caddy" "fehlgeschlagen"; ok=1
fi

echo
echo "--- Selbstheilung scharf testen (Caddy wird absichtlich gekillt) ---"
MAIN=$(systemctl show caddy -p MainPID --value)
kill -9 "$MAIN" 2>/dev/null || true
for i in $(seq 1 20); do
  sleep 1
  [[ "$(systemctl is-active caddy)" == active ]] && break
done
NEW=$(systemctl show caddy -p MainPID --value)
if [[ "$(systemctl is-active caddy)" == active && "$NEW" != "$MAIN" && "$NEW" != 0 ]]; then
  echo "  ✓ nach kill -9 selbst wieder hochgekommen (PID $MAIN → $NEW)"
else
  echo "  ✗ nach kill -9 NICHT wieder hochgekommen"; ok=1
fi

echo
if [[ $ok -eq 0 ]]; then
  echo "Alles grün."
else
  echo "Mindestens eine Prüfung fehlgeschlagen. Rückbau:"
  echo "  sudo cp -a $BACKUP_DROPIN $DROPIN && sudo cp -a $BACKUP_CADDY $CADDYFILE \\"
  echo "    && sudo systemctl daemon-reload && sudo systemctl restart caddy"
  exit 1
fi
