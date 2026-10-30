#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Nightly encrypted backup of Chattr prod (CHAT-26). Runs as root on the prod
# box from chattr-backup.timer and leaves one age-encrypted bundle per night
# in OUT_DIR, where the other server collects it (chattr-backup-pull.sh).
#
# Why this shape:
# - Before, backups only happened right before a server deploy (17 days apart
#   at worst), sat on the same box, and missed the storage volume, the .env
#   (VAULT_ENC_KEY: without it the Vault entries in the dump stay unreadable)
#   and the TURN secret.
# - Encrypted to a public key only. The private key is on no server, so
#   neither this box nor the one that collects the bundles can read them.
# - Collected, not pushed: this box holds no credential for the other one, so
#   whoever takes it over cannot delete the copies there.
#
# Config: /etc/chattr-backup.conf with AGE_RECIPIENT=age1… (optional OUT_DIR,
# KEEP, PULL_GROUP). Restore: CLAUDE.md, section on the update watch.
set -euo pipefail
umask 077
cd /

CONF=/etc/chattr-backup.conf
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
: "${AGE_RECIPIENT:?AGE_RECIPIENT fehlt in $CONF}"
OUT_DIR="${OUT_DIR:-/var/backups/chattr}"
KEEP="${KEEP:-7}"
PULL_GROUP="${PULL_GROUP:-gerry}"

fail() { echo "FEHLER: $*" >&2; exit 1; }

stamp=$(date +%Y%m%d-%H%M%S)
work=$(mktemp -d /var/tmp/chattr-backup.XXXXXX)
trap 'rm -rf "$work"' EXIT
b="$work/chattr-$stamp"
mkdir "$b"

# Every dump is judged by its RESULT, not by an exit code: in a pipe the code
# belongs to gzip, which is content with a dump that stopped after two lines.
# The checks use `grep -c`, never `grep -q`: -q stops reading at the first
# hit, zcat dies of SIGPIPE, and under pipefail the check fails on a good dump
# (first run, 2026-10-29).

echo "== Supabase-Datenbank"
docker exec supabase-db sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" exec pg_dumpall -U postgres' \
  </dev/null | gzip > "$b/supabase-db.sql.gz"
gzip -t "$b/supabase-db.sql.gz" || fail "Supabase-Dump ist kaputt"
zcat "$b/supabase-db.sql.gz" | tail -n 5 | grep -c 'PostgreSQL database cluster dump complete' >/dev/null \
  || fail "Supabase-Dump ist abgeschnitten"
size=$(stat -c %s "$b/supabase-db.sql.gz")
[ "$size" -gt 1000000 ] || fail "Supabase-Dump zu klein ($size Bytes)"
echo "   $size Bytes"

echo "== CMS-Datenbank (chattr.at)"
cms_db=$(docker ps -q --filter label=com.docker.compose.project=chattr-cms \
  --filter label=com.docker.compose.service=db | head -n 1)
[ -n "$cms_db" ] || fail "CMS-Datenbank läuft nicht"
docker exec "$cms_db" sh -c 'export MYSQL_PWD="$MARIADB_PASSWORD"; exec mariadb-dump \
  --single-transaction --routines --triggers --events --hex-blob \
  --default-character-set=utf8mb4 -u"$MARIADB_USER" "$MARIADB_DATABASE"' \
  </dev/null | gzip > "$b/cms-db.sql.gz"
gzip -t "$b/cms-db.sql.gz" || fail "CMS-Dump ist kaputt"
zcat "$b/cms-db.sql.gz" | tail -n 1 | grep -c '^-- Dump completed' >/dev/null \
  || fail "CMS-Dump ist abgeschnitten"
zcat "$b/cms-db.sql.gz" | grep -c 'CREATE TABLE `elements_sites`' >/dev/null \
  || fail "Tabelle elements_sites fehlt im CMS-Dump"
echo "   $(stat -c %s "$b/cms-db.sql.gz") Bytes"

echo "== Dateien"
# The release APKs (3.4 GB) are left out: every one is rebuilt from its tag.
# Two things a restore needs that are easy to miss (both bit the move to
# Netcup in July):
# - --xattrs: storage keeps each object's metadata in user.supabase.*
#   extended attributes. Without them every object answers 500 (ENODATA).
# - supabase_db-config: holds pgsodium_root.key, which encrypts the Vault.
#   It is not in .env; without it the Vault entries (service role key, TURN
#   secret) stay unreadable and push dies silently.
# Exit code 1 from GNU tar means a file changed while it was read (storage
# keeps taking uploads); that copy is still usable, anything above is not.
DB_CONFIG=var/lib/docker/volumes/supabase_db-config/_data
tar -C / -cf "$b/files.tar" --warning=no-file-changed \
  --xattrs --xattrs-include='user.*' --numeric-owner \
  --exclude='home/gerry/chattr-cms/web/uploads/releases' \
  home/chattr/app/supabase/.env \
  home/chattr/app/supabase/volumes/storage \
  "$DB_CONFIG" \
  opt/chattr-turn \
  etc/caddy \
  home/gerry/chattr-cms/.env \
  home/gerry/chattr-cms/config \
  || [ $? -eq 1 ] || fail "tar ist gescheitert"
for must in home/chattr/app/supabase/.env opt/chattr-turn/secret etc/caddy/Caddyfile \
            "$DB_CONFIG/pgsodium_root.key"; do
  tar -tf "$b/files.tar" "$must" >/dev/null 2>&1 || fail "$must fehlt im Archiv"
done
echo "   $(stat -c %s "$b/files.tar") Bytes"

echo "== Verschlüsseln"
install -d -m 0750 -o root -g "$PULL_GROUP" "$OUT_DIR"
rm -f "$OUT_DIR"/*.part
name="chattr-$stamp.tar.age"
tar -C "$work" -cf - "chattr-$stamp" | age -r "$AGE_RECIPIENT" -o "$OUT_DIR/$name.part"
[ "$(head -c 21 "$OUT_DIR/$name.part")" = "age-encryption.org/v1" ] \
  || fail "Ausgabe ist kein age-Format"
# Checksum first, bundle second: the collector skips *.part and only takes a
# bundle whose checksum is already there.
hash=$(sha256sum "$OUT_DIR/$name.part" | cut -d ' ' -f 1)
printf '%s  %s\n' "$hash" "$name" > "$OUT_DIR/$name.sha256"
mv "$OUT_DIR/$name.part" "$OUT_DIR/$name"
chgrp "$PULL_GROUP" "$OUT_DIR/$name" "$OUT_DIR/$name.sha256"
chmod 0640 "$OUT_DIR/$name" "$OUT_DIR/$name.sha256"

# Only the newest KEEP stay here; the collector keeps its own, longer history.
ls -1t "$OUT_DIR"/chattr-*.tar.age | tail -n +"$((KEEP + 1))" | while read -r old; do
  rm -f "$old" "$old.sha256"
done

echo "== fertig: $OUT_DIR/$name ($(stat -c %s "$OUT_DIR/$name") Bytes)"
