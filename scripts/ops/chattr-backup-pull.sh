#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Collects the nightly encrypted Chattr backups from the prod box (CHAT-26).
# Runs on the OTHER server as gerry, by cron, after chattr-backup.timer:
#
#   45 3 * * *  $HOME/bin/chattr-backup-pull.sh >/dev/null 2>&1
#
# The prod side lets this key do nothing but read its backup folder
# (authorized_keys: from=<this host>, restrict, command="rrsync -ro …").
# Never --delete: a prod box that is lost or taken over must not take these
# copies with it. Retention here is our own and longer than there.
#
# Reports over pipepush (project chattr, pipeline backup) only on CHANGE, plus
# a summary on Mondays as a sign of life: a watch that dies silently is the
# trap it guards against. The bundles stay encrypted here; the key to them is
# on no server.
#
# DRY_RUN=1 prints the message instead of sending it and leaves the state alone.
set -u

SRC="${SRC:-chattr-backup-src:./}"        # ssh alias, see ~/.ssh/config
DEST="${DEST:-$HOME/backups/chattr-pull}"
KEEP="${KEEP:-30}"
MAX_AGE_H="${MAX_AGE_H:-26}"
HEARTBEAT_DOW="${HEARTBEAT_DOW:-1}"       # date +%u; empty = off
SERVER="https://pipepush.geraldhofbauer.net"
TOKEN_FILE="$HOME/.config/chattr-backup/token"
STATE_FILE="$HOME/.local/state/chattr-backup-pull.state"
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "$DEST" "$(dirname "$STATE_FILE")"
chmod 700 "$DEST"

notify() { # $1=status  $2=text
  if [ "$DRY_RUN" = 1 ]; then printf '[DRY_RUN] %s: %s\n' "$1" "$2"; return; fi
  [ -r "$TOKEN_FILE" ] || { echo "kein Token in $TOKEN_FILE" >&2; return 1; }
  python3 -c 'import json,sys; print(json.dumps({"token":sys.argv[1],"status":sys.argv[2],"pipeline":"backup","message":sys.argv[3]}))' \
    "$(cat "$TOKEN_FILE")" "$1" "$2" \
  | curl -sf -X POST "$SERVER/api/webhook" -H "Content-Type: application/json" --data-binary @- >/dev/null 2>&1
}

problems=()

if ! out=$(rsync -a --exclude='*.part' --timeout=600 "$SRC" "$DEST/" 2>&1); then
  problems+=("Abholen gescheitert: $(printf '%s' "$out" | tail -n 1)")
fi

# Check each bundle once: checksum from the prod side, and the age header.
# Reading all of them every night would mean gigabytes for nothing.
for f in "$DEST"/chattr-*.tar.age; do
  [ -e "$f" ] || continue
  [ -e "$f.verified" ] && continue
  n=$(basename "$f")
  if [ ! -e "$f.sha256" ]; then
    problems+=("$n ohne Prüfsumme"); continue
  fi
  if ! (cd "$DEST" && sha256sum -c --quiet "$n.sha256" >/dev/null 2>&1); then
    problems+=("$n: Prüfsumme stimmt nicht"); continue
  fi
  if [ "$(head -c 21 "$f")" != "age-encryption.org/v1" ]; then
    problems+=("$n: kein age-Format"); continue
  fi
  touch "$f.verified"
done

newest=$(ls -1t "$DEST"/chattr-*.tar.age 2>/dev/null | head -n 1)
if [ -z "$newest" ]; then
  problems+=("noch keine Sicherung abgeholt")
else
  age_h=$(( ($(date +%s) - $(stat -c %Y "$newest")) / 3600 ))
  [ "$age_h" -lt "$MAX_AGE_H" ] || problems+=("neueste Sicherung ist ${age_h} h alt")
fi

ls -1t "$DEST"/chattr-*.tar.age 2>/dev/null | tail -n +"$((KEEP + 1))" | while read -r old; do
  rm -f "$old" "$old.sha256" "$old.verified"
done

PREV=""
# shellcheck disable=SC1090
[ -r "$STATE_FILE" ] && . "$STATE_FILE"

count=$(ls -1 "$DEST"/chattr-*.tar.age 2>/dev/null | wc -l)
summary="$count Sicherungen da"
[ -n "$newest" ] && summary="$summary, neueste $(basename "$newest") ($(du -h "$newest" | cut -f 1))"

if [ "${#problems[@]}" -gt 0 ]; then
  text=$(printf '%s; ' "${problems[@]}"); text=${text%; }
  [ "$PREV" = bad ] || notify failure "Chattr-Sicherung: $text"
  NOW=bad
else
  if [ "$PREV" != ok ]; then
    notify success "Chattr-Sicherung läuft: $summary"
  elif [ -n "$HEARTBEAT_DOW" ] && [ "$(date +%u)" = "$HEARTBEAT_DOW" ]; then
    notify success "Chattr-Sicherung, Wochenbericht: $summary"
  fi
  NOW=ok
fi

[ "$DRY_RUN" = 1 ] && { echo "Zustand wäre: $NOW"; exit 0; }
printf 'PREV=%s\n' "$NOW" > "$STATE_FILE"
