#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Runs ON THE BACKUP BOX (IONOS) from cron, nightly. Pulls one encrypted
# archive from prod over a dedicated SSH key whose only allowed command is
# chattr-backup-export.sh, checks it, keeps the last N, reports via pipepush.
# CHAT-26: until now backups only happened before a deploy (17 days apart at
# worst) and only on the prod box itself, gone with it if the box goes.
#
# Config (env, or ~/.config/chattr-backup/pull.env):
#   CHATTR_BACKUP_HOST   ssh target, e.g. chattr@<prod-host> (required)
#   CHATTR_BACKUP_KEY    ssh key (default ~/.ssh/chattr_backup_pull)
#   CHATTR_BACKUP_DIR    where archives go (default ~/backups/chattr)
#   CHATTR_BACKUP_KEEP   how many to keep (default 14)
#   PIPEPUSH_TOKEN_FILE  token for reports (default ~/.config/chattr-backup/token)
#   PIPEPUSH_SERVER      default https://pipepush.geraldhofbauer.net
set -uo pipefail

conf="${HOME}/.config/chattr-backup/pull.env"
# shellcheck disable=SC1090
[ -f "$conf" ] && . "$conf"

host="${CHATTR_BACKUP_HOST:-}"
key="${CHATTR_BACKUP_KEY:-$HOME/.ssh/chattr_backup_pull}"
dir="${CHATTR_BACKUP_DIR:-$HOME/backups/chattr}"
keep="${CHATTR_BACKUP_KEEP:-14}"
token_file="${PIPEPUSH_TOKEN_FILE:-$HOME/.config/chattr-backup/token}"
server="${PIPEPUSH_SERVER:-https://pipepush.geraldhofbauer.net}"

report() { # status message
  [ -f "$token_file" ] || return 0
  # Same contract as chattr-uptime.sh: the token travels in the body.
  curl -sf --max-time 15 -X POST "$server/api/webhook" \
    -H 'Content-Type: application/json' \
    -d "{\"token\":\"$(cat "$token_file")\",\"status\":\"$1\",\"pipeline\":\"backup\",\"message\":\"$2\"}" \
    >/dev/null 2>&1 || true
}

fail() { echo "chattr-backup-pull: $*" >&2; report failed "$*"; exit 1; }

[ -n "$host" ] || fail "CHATTR_BACKUP_HOST not set"
mkdir -p "$dir" && chmod 700 "$dir"
stamp="$(date -u +%Y%m%d-%H%M%S)"
out="$dir/chattr-$stamp.tar.age"
part="$out.part"

# The remote side runs its forced command whatever we send; nothing to pass.
if ! ssh -i "$key" -o BatchMode=yes -o ConnectTimeout=20 "$host" > "$part"; then
  rm -f "$part"; fail "ssh/export failed"
fi

# An age file starts with this line; a short or text answer is an error message.
head -c 22 "$part" | grep -q '^age-encryption.org/v1' || { rm -f "$part"; fail "not an age archive"; }
size=$(wc -c < "$part")
[ "$size" -ge 100000 ] || { rm -f "$part"; fail "archive only $size bytes"; }
chmod 600 "$part" && mv "$part" "$out"

# Keep the newest $keep.
ls -1t "$dir"/chattr-*.tar.age 2>/dev/null | tail -n +"$((keep + 1))" | xargs -r rm -f

# Quiet on success, except one line a week as a sign of life.
if [ "$(date +%u)" = "1" ]; then
  report succeeded "backup ok: $(du -h "$out" | cut -f1), $(ls -1 "$dir"/chattr-*.tar.age | wc -l) kept"
fi
echo "✓ $out ($size bytes)"
