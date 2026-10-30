#!/usr/bin/env bash
# Adds the no-cache header for /download/maintenance.json to the Caddyfile.
#
# Why no-cache is the whole point: the maintenance switch
# (lib/core/init/maintenance_flag.dart) keeps devices from deleting themselves
# when the server says "this account does not exist". A cached answer of "no
# maintenance" would be wrong at exactly the moment the file has just been set —
# the switch would silently fail to take.
#
# sudo bash ~/caddy-maintenance-header.sh # on sudo bash ~/caddy-maintenance-
# header.sh --zurueck # restore the last backup
set -euo pipefail

CADDYFILE=/etc/caddy/Caddyfile
MARKE='header /maintenance.json'

if [ "${1:-}" = "--zurueck" ]; then
  LETZTE=$(ls -1t "$CADDYFILE".bak-maint-* 2>/dev/null | head -1 || true)
  [ -n "$LETZTE" ] || { echo "Keine Sicherung gefunden."; exit 1; }
  cp "$LETZTE" "$CADDYFILE"
  systemctl reload caddy
  echo "Zurueckgesetzt aus $LETZTE und neu geladen."
  exit 0
fi

if grep -qF "$MARKE" "$CADDYFILE"; then
  echo "Steht schon drin -- nichts zu tun."
  exit 0
fi

SICHERUNG="$CADDYFILE.bak-maint-$(date +%Y%m%d-%H%M%S)"
cp "$CADDYFILE" "$SICHERUNG"
echo "Sicherung: $SICHERUNG"

# Insert before the file_server INSIDE handle_path /download/*.
awk '
  /handle_path \/download\/\*/ { drin = 1 }
  drin && !fertig && /^[[:space:]]*file_server[[:space:]]*$/ {
    print "\t\t# Der Wartungsschalter (lib/core/init/maintenance_flag.dart)."
    print "\t\t# no-cache ist hier kein Feinschliff: Eine gecachte Antwort"
    print "\t\t# \"keine Wartung\" waere genau dann falsch, wenn die Datei"
    print "\t\t# gerade gesetzt wurde."
    print "\t\theader /maintenance.json {"
    print "\t\t\tCache-Control \"no-cache, must-revalidate\""
    print "\t\t\tContent-Type \"application/json\""
    print "\t\t}"
    fertig = 1
  }
  { print }
  END { if (!fertig) exit 3 }
' "$CADDYFILE" > "$CADDYFILE.neu" || {
  echo "FEHLER: die Stelle (file_server in handle_path /download/*) nicht gefunden -- nichts geaendert."
  rm -f "$CADDYFILE.neu"; exit 3
}

mv "$CADDYFILE.neu" "$CADDYFILE"

# Validate first, then load. A broken Caddyfile must not touch prod.
#
# `caddy validate` needs the same environment as the service: the tls block
# fetches its Cloudflare token via {env.CF_API_TOKEN}, and systemd passes that
# in through an EnvironmentFile. Without sourcing it the placeholder is empty,
# the DNS module refuses with "API token '' appears invalid" — and the check
# would discard a perfectly healthy file.
ENVFILE=/etc/caddy/cloudflare.env
if [ -r "$ENVFILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENVFILE"
  set +a
fi

if ! caddy validate --adapter caddyfile --config "$CADDYFILE" >/tmp/caddy-validate.log 2>&1; then
  echo "FEHLER: caddy validate hat abgelehnt -- setze zurueck:"
  tail -20 /tmp/caddy-validate.log
  cp "$SICHERUNG" "$CADDYFILE"
  exit 4
fi

systemctl reload caddy
echo
echo "Geladen. Gegenprobe:"
curl -sI https://chattr.geraldhofbauer.net/download/maintenance.json \
  | grep -iE '^(HTTP|cache-control|content-type)' || true
echo
echo "Wartung EIN:  echo '{\"maintenance\": true}' > /home/chattr/app/downloads/maintenance.json"
echo "Wartung AUS:  rm -f /home/chattr/app/downloads/maintenance.json"
