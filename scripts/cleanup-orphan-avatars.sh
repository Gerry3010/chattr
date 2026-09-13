#!/usr/bin/env bash
# Clean up orphaned avatar objects.
#
# Why they exist: the object name carries the file extension
# (`<uuid>/avatar.<ext>`), and uploading uses `upsert`. If somebody switches
# from HEIC to JPEG, the upload therefore writes a NEW path — the old object
# stays behind and nothing points at it any more. The same happens when a group
# picture is removed: `clearGroupAvatar` only sets the column to NULL
# (chats_repository.dart).
#
# Why this is more than tidiness: the buckets are publicly readable. An orphaned
# object is therefore still fetchable without signing in — including the
# pictures of deleted accounts and including the EXIF data that HEIC smuggled
# past the strip path (which can only do JPEG and PNG).
#
# The default is a DRY RUN. It shows what would be deleted and creates the
# backup. Only `--apply` deletes.
#
# scripts/cleanup-orphan-avatars.sh # look only + back up scripts/cleanup-
# orphan-avatars.sh --apply # back up and delete
set -euo pipefail

SSH_HOST="${SSH_HOST:-nc-chattr}"
API="${API:-https://api.chattr.geraldhofbauer.net}"
APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/orphan-avatars-$STAMP}"

echo "Server:    $SSH_HOST"
echo "Sicherung: $BACKUP_DIR"
echo "Modus:     $([[ $APPLY == 1 ]] && echo 'LÖSCHEN' || echo 'Trockenlauf')"
echo

# The service key lies in the storage container's environment. It is needed
# because this script must go on working even once the buckets are no longer
# public.
SERVICE_KEY="$(ssh "$SSH_HOST" \
  "docker inspect supabase-storage --format '{{range .Config.Env}}{{println .}}{{end}}' \
   | sed -n 's/^SERVICE_KEY=//p'")"
if [[ -z "$SERVICE_KEY" ]]; then
  echo "FEHLER: SERVICE_KEY nicht gefunden." >&2
  exit 1
fi

# Verwaist = kein profiles.avatar_path und kein chats.avatar_path zeigt darauf.
ORPHANS="$(ssh "$SSH_HOST" "docker exec supabase-db psql -U postgres -tAc \"
  SELECT o.bucket_id || '|' || o.name || '|' || COALESCE((o.metadata->>'size'),'0')
    FROM storage.objects o
    LEFT JOIN profiles p ON p.avatar_path = o.name
    LEFT JOIN chats c    ON c.avatar_path = o.name
   WHERE o.bucket_id IN ('avatars','group-avatars')
     AND p.id IS NULL AND c.id IS NULL
   ORDER BY o.bucket_id, o.name\"")"

if [[ -z "$ORPHANS" ]]; then
  echo "Nichts verwaist — fertig."
  exit 0
fi

mkdir -p "$BACKUP_DIR"
COUNT=0
FAILED=0

while IFS='|' read -r BUCKET NAME SIZE; do
  [[ -z "$BUCKET" ]] && continue
  COUNT=$((COUNT + 1))
  TARGET="$BACKUP_DIR/$BUCKET/$(dirname "$NAME")"
  mkdir -p "$TARGET"

  # Back up first, then delete — never the other way round.
  HTTP=$(curl -sS -m 120 -o "$TARGET/$(basename "$NAME")" -w '%{http_code}' \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    "$API/storage/v1/object/$BUCKET/$NAME")
  GOT=$(stat -c%s "$TARGET/$(basename "$NAME")" 2>/dev/null || echo 0)

  if [[ "$HTTP" != "200" || "$GOT" != "$SIZE" ]]; then
    echo "  ÜBERSPRUNGEN $BUCKET/$NAME — Sicherung unvollständig (HTTP $HTTP, $GOT von $SIZE Bytes)"
    FAILED=$((FAILED + 1))
    continue
  fi
  echo "  gesichert    $BUCKET/$NAME ($SIZE Bytes)"

  if [[ $APPLY == 1 ]]; then
    DEL=$(curl -sS -m 60 -o /dev/null -w '%{http_code}' -X DELETE \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
      "$API/storage/v1/object/$BUCKET/$NAME")
    if [[ "$DEL" == "200" ]]; then
      echo "  GELÖSCHT     $BUCKET/$NAME"
    else
      echo "  FEHLER       $BUCKET/$NAME — DELETE ergab HTTP $DEL"
      FAILED=$((FAILED + 1))
    fi
  fi
done <<< "$ORPHANS"

echo
echo "$COUNT verwaiste Objekte, $FAILED Probleme."
if [[ $APPLY == 0 ]]; then
  echo "Trockenlauf — nichts gelöscht. Sicherung liegt in $BACKUP_DIR."
  echo "Zum Ausführen: $0 --apply"
fi
