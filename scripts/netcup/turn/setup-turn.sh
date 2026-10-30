#!/usr/bin/env bash
# Sets up / updates coturn in /opt/chattr-turn and puts its secret into the
# Supabase Vault (turn_secret + turn_uris, read by 00086). Runs as gerry on
# the Netcup box, no sudo — open-firewall.sh (sudo) must have run once.
#
#   scp -r scripts/netcup/turn nc-chattr:/tmp/chattr-turn-src
#   ssh nc-chattr 'bash /tmp/chattr-turn-src/setup-turn.sh && rm -rf /tmp/chattr-turn-src'
#
# Idempotent: an existing secret is kept, so issued credentials stay valid.
# The secret is never printed and never on a command line (ps would show it).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST=/opt/chattr-turn
HOST=turn.chattr.at
DB_CONTAINER=${DB_CONTAINER:-supabase-db}

[ -d "$DST" ] && [ -w "$DST" ] || { echo "✗ $DST fehlt oder ist nicht schreibbar — erst open-firewall.sh"; exit 1; }

IPV4=$(ip -4 -o addr show dev eth0 scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
IPV6=$(ip -6 -o addr show dev eth0 scope global | awk '{print $4}' | cut -d/ -f1 | grep -v '^fd' | head -1)
[ -n "$IPV4" ] && [ -n "$IPV6" ] || { echo "✗ öffentliche Adressen nicht gefunden"; exit 1; }

umask 077
SECRET_FILE="$DST/secret"
[ -s "$SECRET_FILE" ] || head -c 48 /dev/urandom | base64 -w0 | tr -d '/+=' > "$SECRET_FILE"
SECRET=$(cat "$SECRET_FILE")

sed -e "s|__IPV4__|$IPV4|g" -e "s|__IPV6__|$IPV6|g" \
    -e "s|__SECRET__|$SECRET|" "$SRC/turnserver.conf.template" > "$DST/turnserver.conf"
install -m 0644 "$SRC/docker-compose.yml" "$DST/docker-compose.yml"

( cd "$DST" && docker compose up -d --force-recreate )

URIS="stun:$HOST:3478,turn:$HOST:3478?transport=udp,turn:$HOST:3478?transport=tcp"
# Delete + create rather than update: after a box move the old ciphertext is
# unreadable under a new pgsodium key (see the Netcup migration notes).
docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q <<SQL >/dev/null
DELETE FROM vault.secrets WHERE name IN ('turn_secret','turn_uris');
SELECT vault.create_secret('$SECRET', 'turn_secret');
SELECT vault.create_secret('$URIS', 'turn_uris');
SQL

docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -tA \
  -c "SELECT name || '=' || (length(decrypted_secret) > 0) FROM vault.decrypted_secrets WHERE name LIKE 'turn_%' ORDER BY 1"
docker ps --filter name=chattr-turn --format '{{.Names}} {{.Status}}'
echo "✓ coturn läuft, Vault gesetzt ($URIS)"
