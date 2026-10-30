#!/usr/bin/env bash
# 02-cutover-dump-prod.sh — run ON THE CURRENT PROD SERVER (<staging-host>) as a
# user that can sudo. Maintenance-window step: takes a safety pg_dump, STOPS the
# stack (write-freeze), and packs the raw PGDATA + storage volumes for transfer.
#
# ⚠️ DESTRUCTIVE to availability: `docker compose down` takes Chattr OFFLINE until
#    the Netcup side is up and DNS is flipped. Run inside the agreed window.
set -euo pipefail

SUPA_DIR="${SUPA_DIR:-/home/chattr/app/supabase}"
OUT_DIR="${OUT_DIR:-/home/chattr/migrate-$(date +%Y%m%d-%H%M)}"
NETCUP_HOST="${NETCUP_HOST:-}"          # e.g. chattr@<netcup-ip>  (optional: auto-scp if set)
DB_SVC="db"

log() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
cd "$SUPA_DIR"
mkdir -p "$OUT_DIR"

# Load POSTGRES_DB / POSTGRES_USER from the stack .env (defaults match supabase).
POSTGRES_DB="$(grep -E '^POSTGRES_DB=' .env | cut -d= -f2- || true)"; POSTGRES_DB="${POSTGRES_DB:-postgres}"

log "1/5  Safety-Backup: logischer pg_dump (Rollback-Artefakt) — Stack läuft noch"
docker compose exec -T "$DB_SVC" pg_dump -U postgres -Fc "$POSTGRES_DB" > "$OUT_DIR/rollback-${POSTGRES_DB}.dump"
echo "     → $OUT_DIR/rollback-${POSTGRES_DB}.dump ($(du -h "$OUT_DIR/rollback-${POSTGRES_DB}.dump" | cut -f1))"

log "2/5  Copy .env + FCM-Service-Account (verbatim, KRITISCH: Anon/JWT/Keys)"
cp -av .env "$OUT_DIR/.env"
[ -f .fcm_sa.json ] && cp -av .fcm_sa.json "$OUT_DIR/.fcm_sa.json" || echo "     (kein .fcm_sa.json — ok falls nicht genutzt)"

log "3/5  WRITE-FREEZE: Stack stoppen (Chattr geht jetzt offline)"
read -r -p "     Wirklich 'docker compose down'? Clients gehen offline. [yes/NO] " ok
[ "$ok" = "yes" ] || { echo "Abgebrochen."; exit 1; }
docker compose down

log "4/5  Volumes packen (roh, --numeric-owner für uid-Treue, als root)"
sudo tar -C volumes/db      --numeric-owner -czf "$OUT_DIR/db_data.tgz"  data
# ⚠️ --xattrs MANDATORY: Supabase storage puts object metadata on the files as
# POSIX extended attributes (user.supabase.*). Without --xattrs they are missing
# → storage-api throws 500 "ENODATA / extended attribute does not exist" on
# EVERY object (avatars + media dead). Lesson of 2026-07-22. (rsync alternative:
# -aX.)
sudo tar -C volumes --xattrs --xattrs-include='*' --numeric-owner -czf "$OUT_DIR/storage.tgz"  storage
sudo chown "$(id -u):$(id -g)" "$OUT_DIR"/*.tgz
echo "     db_data.tgz=$(du -h "$OUT_DIR/db_data.tgz"|cut -f1)  storage.tgz=$(du -h "$OUT_DIR/storage.tgz"|cut -f1)"

log "5/5  Transfer nach Netcup"
if [ -n "$NETCUP_HOST" ]; then
  rsync -avP "$OUT_DIR"/ "${NETCUP_HOST}:/home/chattr/migrate-in/"
  echo "     → nach ${NETCUP_HOST}:/home/chattr/migrate-in/ übertragen."
else
  cat <<EOF
     NETCUP_HOST nicht gesetzt → manuell übertragen, z.B.:
       rsync -avP "$OUT_DIR"/ chattr@<netcup-ip>:/home/chattr/migrate-in/
EOF
fi

cat <<EOF

✅ Prod-Seite fertig. Stack ist GESTOPPT (Rollback: 'cd $SUPA_DIR && docker compose up -d').
   Weiter auf Netcup mit 03-restore-up-netcup.sh (SRC=/home/chattr/migrate-in).
   Tipp: Storage kann vorab live gesynct sein → dann war Schritt 4 nur ein schnelles Delta.
EOF
