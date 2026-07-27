#!/usr/bin/env bash
# scripts/pipepush_notify.sh
#
# Schickt EINE pipepush-Benachrichtigung, angereichert um:
#   - einen klickbaren Build-Log-Link zur Pipeline-Ausführung, und
#   - (best-effort, nur bei Fehler) den Tail einer lokalen pipe.log, die der
#     Step selbst per tee schreibt.
#
# Hintergrund zur Tail-Quelle: Bitbucket stellt das Step-Log NICHT als Datei
# bereit, die ein after-script taillen könnte, und über die REST-API ist es zur
# after-script-Zeit noch nicht geschrieben (E2E verifiziert: das Log enthält
# nachher sogar die after-script-Zeile selbst). Der EINZIGE zuverlässige Weg ist
# daher, dass der Step seinen Output selbst nach $BITBUCKET_CLONE_DIR/pipe.log
# tee-t. Steps ohne pipe.log (z.B. der Prod-Deploy, der unangetastet bleibt)
# bekommen weiterhin die Link-only-Notification.
#
# Aufruf aus einem after-script:
#   bash scripts/pipepush_notify.sh <pipeline-name> <mode>
#     mode = failure-only  → nur senden, wenn der Step fehlschlug
#     mode = always        → success ODER failure senden
#
# Pflicht-Repo-Vars: PIPEPUSH_SERVER, PIPEPUSH_TOKEN.
# Für den Fehler-Tail: der Step schreibt pipe.log (siehe bitbucket-pipelines.yml,
#   analyze-and-test + Build-Web). Fehlt sie, bleibt es bei Link-only.
#
# ALLES hier ist bewusst non-fatal: ein after-script darf den Build nie rot
# machen. Jede Teil-Operation fällt still auf "weniger Info" zurück.

set -u

PIPELINE="${1:?pipeline name required}"
MODE="${2:-always}"

EXIT_CODE="${BITBUCKET_EXIT_CODE:-0}"
# failure-only: bei Erfolg gar nichts senden (Erfolg meldet ein späterer Step).
if [ "$MODE" = "failure-only" ] && [ "$EXIT_CODE" = "0" ]; then
  exit 0
fi
if [ "$EXIT_CODE" = "0" ]; then STATUS="success"; else STATUS="failure"; fi

WS="${BITBUCKET_WORKSPACE:-}"
REPO="${BITBUCKET_REPO_SLUG:-}"
BUILD="${BITBUCKET_BUILD_NUMBER:-}"
LOG_URL="https://bitbucket.org/${WS}/${REPO}/pipelines/results/${BUILD}"

# --- Fehler-Tail aus lokaler pipe.log (best-effort, nur bei failure) ---------
# Steps, die den Tail wollen, tee-n ihren Output nach $BITBUCKET_CLONE_DIR/pipe.log.
TAIL=""
LOGFILE="${BITBUCKET_CLONE_DIR:-.}/pipe.log"
if [ "$STATUS" = "failure" ] && [ -s "$LOGFILE" ]; then
  ESC=$(printf '\033')
  # ANSI-Farbcodes weg, Control-Chars (außer Tab/Newline) weg, Leerzeilen weg,
  # letzte 15 Zeilen, hart auf 3000 Zeichen deckeln (message kurz halten).
  TAIL=$(sed "s/${ESC}\[[0-9;?]*[a-zA-Z]//g" "$LOGFILE" \
    | tr -d '\000-\010\013-\037\177' \
    | grep -v '^[[:space:]]*$' \
    | tail -15 \
    | head -c 3000)
fi

# --- message JSON-safe bauen (awk ist in allen CI-Images vorhanden) ----------
json_escape() {  # stdin → JSON-String-Rumpf (ohne umschließende Quotes)
  awk 'BEGIN{ORS=""}
    { gsub(/\\/,"\\\\"); gsub(/"/,"\\\"");
      if (NR>1) printf "\\n";
      printf "%s", $0 }'
}

MSG_URL="🔗 Log: ${LOG_URL}"
if [ -n "$TAIL" ]; then
  MESSAGE=$(printf '```\n%s\n```\n%s' "$TAIL" "$MSG_URL")
else
  MESSAGE="$MSG_URL"
fi
MSG_ESC=$(printf '%s' "$MESSAGE" | json_escape)

# branch/commit/build enthalten keine JSON-Sonderzeichen (Git-Ref/Hex/Zahl).
PAYLOAD=$(printf '{"token":"%s","status":"%s","pipeline":"%s","branch":"%s","commit":"%s","runId":"%s","message":"%s"}' \
  "${PIPEPUSH_TOKEN:-}" "$STATUS" "$PIPELINE" \
  "${BITBUCKET_BRANCH:-}" "${BITBUCKET_COMMIT:-}" "$BUILD" "$MSG_ESC")

if [ -z "${PIPEPUSH_SERVER:-}" ] || [ -z "${PIPEPUSH_TOKEN:-}" ]; then
  echo "pipepush_notify: PIPEPUSH_SERVER/PIPEPUSH_TOKEN nicht gesetzt — übersprungen." >&2
  exit 0
fi

curl -sf --max-time 15 -X POST "${PIPEPUSH_SERVER%/}/api/webhook" \
  -H "Content-Type: application/json" -d "$PAYLOAD" >/dev/null 2>&1 \
  || echo "pipepush_notify: Webhook-POST fehlgeschlagen (non-fatal)." >&2
exit 0
