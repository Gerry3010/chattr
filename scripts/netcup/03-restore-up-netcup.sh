#!/usr/bin/env bash
# 03-restore-up-netcup.sh — run ON THE NETCUP VPS as the `chattr` user (needs sudo
# for the volume untar). Unpacks the copied PGDATA + storage into the stack dir,
# restores .env/FCM, and brings the full Supabase stack up.
#
# Precondition: the repo's supabase/ (docker-compose.yml + functions) is already
# on the box at $SUPA_DIR — either via a prior Bitbucket deploy or an rsync of the
# repo `supabase/` dir. This script supplies the DATA + secrets, not the code.
set -euo pipefail

SUPA_DIR="${SUPA_DIR:-/home/chattr/app/supabase}"
SRC="${SRC:-/home/chattr/migrate-in}"     # where 02-*.sh delivered the tarballs

log() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
cd "$SUPA_DIR"

[ -f "$SRC/db_data.tgz" ] && [ -f "$SRC/storage.tgz" ] && [ -f "$SRC/.env" ] || {
  echo "Fehlt: db_data.tgz / storage.tgz / .env in $SRC"; exit 1; }

log "1/5  Secrets einspielen (.env + FCM) — verbatim von Prod"
cp -av "$SRC/.env" .env
[ -f "$SRC/.fcm_sa.json" ] && cp -av "$SRC/.fcm_sa.json" .fcm_sa.json || true

log "2/5  Alten Stack sicher stoppen (falls Testlauf lief) + Volumes leeren"
docker compose down 2>/dev/null || true
sudo rm -rf volumes/db/data volumes/storage
sudo mkdir -p volumes/db volumes/storage

log "3/5  Volumes entpacken (roh, uid-treu)"
sudo tar -C volumes/db --numeric-owner -xzf "$SRC/db_data.tgz"      # → volumes/db/data
sudo tar -C volumes --xattrs --xattrs-include='*' --numeric-owner -xzf "$SRC/storage.tgz"  # → volumes/storage (xattrs = Storage-Objekt-Metadaten, sonst 500 ENODATA!)

log "4/5  Stack hochfahren"
docker compose up -d
echo "     warte auf DB-Health…"
for i in $(seq 1 60); do
  docker compose ps db | grep -q '(healthy)' && break
  sleep 2
done
# migrate is idempotent — PGDATA already has the migration history and applies
# nothing new.
docker compose run --rm migrate || true
docker compose restart functions 2>/dev/null || true

log "5/5  Vault-Secrets ZWINGEND neu anlegen (service_role_key / project_url)"
# ⚠️ CRITICAL (lesson of 2026-07-22): the volume copy brings vault.secrets along
# as prod CIPHERTEXT, encrypted with prod's pgsodium root key. The new box has a
# DIFFERENT pgsodium key → decrypt throws "invalid ciphertext" →
# private.get_secret('service_role_key') is missing → the push trigger swallows
# the net.http_post silently in the EXCEPTION handler → PUSH DEAD (realtime
# keeps running, so it does not stand out at once). Hence NOT `WHERE NOT EXISTS`
# (that adopts the broken prod ciphertext) but DELETE + recreate → re-encrypted
# with the new box's key. Value interpolation via a stdin heredoc (psql's `:'v'`
# does not work reliably in `-c`); JWT/URL are quote-safe.
SRK="$(grep -E '^SERVICE_ROLE_KEY=' .env | cut -d= -f2-)"
AEU="$(grep -E '^SUPABASE_PUBLIC_URL=' .env | cut -d= -f2-)"
docker compose exec -T db psql -U postgres -v ON_ERROR_STOP=0 <<PSQL || true
DELETE FROM vault.secrets WHERE name IN ('service_role_key','project_url');
SELECT vault.create_secret('$SRK','service_role_key');
SELECT vault.create_secret('$AEU','project_url');
PSQL
# Verify that it decrypts (fail loudly if not):
docker compose exec -T db psql -U postgres \
  -c "SELECT length(private.get_secret('service_role_key')) AS srk_decrypted_len;" || true

cat <<EOF

✅ Netcup-Stack läuft mit den Prod-Daten. Jetzt:
   • 04-verify.sh laufen lassen (Health/Row-Counts/Media/Realtime).
   • TLS-Cert für api.chattr… muss auf dieser Box liegen (Vorlauf per DNS-01).
   • Dann DNS-A-Records api./app./chattr.geraldhofbauer.net → diese Netcup-IP.
   • Rollback: DNS zurück + Prod 'docker compose up -d'.
EOF
