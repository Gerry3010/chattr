#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Runs ON THE PROD BOX (as the user that owns the compose stack) and writes ONE
# encrypted archive to stdout: database dump, the stack's .env (it holds
# VAULT_ENC_KEY; without it the vault entries in the dump stay unreadable),
# the TURN secret, and optionally the storage volume. CHAT-26.
#
# It is meant as the forced command of a dedicated SSH key, so the box that
# pulls the backup can run exactly this and nothing else:
#
#   command="$HOME/bin/chattr-backup-export.sh",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAA… chattr-backup-pull
#
# Encrypted with age to a RECIPIENT key (public half only on this box). The
# private half lives offline with Gerry. So neither this box nor the one that
# stores the archives can read old backups: a compromised prod cannot read or
# meaningfully tamper with what was saved before.
#
# Config (env, or ~/.config/chattr-backup/export.env):
#   CHATTR_STACK_DIR      compose directory (default /home/chattr/app/supabase)
#   CHATTR_TURN_SECRET    TURN secret file (default /opt/chattr-turn/secret)
#   CHATTR_AGE_RECIPIENT  age public key (age1…), required
#   CHATTR_BACKUP_STORAGE 1 = include volumes/storage (default 0)
set -euo pipefail

conf="${HOME}/.config/chattr-backup/export.env"
# shellcheck disable=SC1090
[ -f "$conf" ] && . "$conf"

stack="${CHATTR_STACK_DIR:-/home/chattr/app/supabase}"
turn_secret="${CHATTR_TURN_SECRET:-/opt/chattr-turn/secret}"
recipient="${CHATTR_AGE_RECIPIENT:-}"
with_storage="${CHATTR_BACKUP_STORAGE:-0}"

die() { echo "chattr-backup-export: $*" >&2; exit 1; }
[ -n "$recipient" ] || die "CHATTR_AGE_RECIPIENT not set"
command -v age >/dev/null || die "age not installed"
[ -d "$stack" ] || die "no stack at $stack"

work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

# The dump: checked by its RESULT, as in the deploy (a pipe returns the code of
# gzip, which is content even when pg_dumpall broke off after two lines).
(cd "$stack" && docker compose exec -T db pg_dumpall -U postgres < /dev/null) \
  | gzip > "$work/db.sql.gz"
gzip -t "$work/db.sql.gz" || die "dump is not an intact archive"
[ "$(wc -c < "$work/db.sql.gz")" -ge 100000 ] || die "dump suspiciously small"

cp "$stack/.env" "$work/supabase.env"
[ -f "$turn_secret" ] && cp "$turn_secret" "$work/turn.secret"

items=(db.sql.gz supabase.env)
[ -f "$work/turn.secret" ] && items+=(turn.secret)
date -u +%Y-%m-%dT%H:%M:%SZ > "$work/created_at"
items+=(created_at)

if [ "$with_storage" = "1" ] && [ -d "$stack/volumes/storage" ]; then
  tar -C "$stack/volumes" -cf "$work/storage.tar" storage
  items+=(storage.tar)
fi

tar -C "$work" -cf - "${items[@]}" | age -r "$recipient"
