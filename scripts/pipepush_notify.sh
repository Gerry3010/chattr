#!/usr/bin/env bash
# scripts/pipepush_notify.sh
#
# Sends ONE pipepush notification, enriched with:
#   - a clickable build-log link to the pipeline run, and
#   - (best effort, on failure only) the tail of a local pipe.log that the step
#     itself writes via tee.
#
# Background on the tail's source: Bitbucket does NOT provide the step log as a file
# an after-script could tail, and through the REST API it is not yet written at
# after-script time (verified end to end: the log afterwards even contains the
# after-script line itself). The ONLY reliable route is therefore for the step to
# tee its own output to $BITBUCKET_CLONE_DIR/pipe.log. Steps without a pipe.log
# (e.g. the prod deploy, which stays untouched) still get the link-only
# notification.
#
# Called from an after-script:
#   bash scripts/pipepush_notify.sh <pipeline-name> <mode>
#     mode = failure-only  → send only when the step failed
#     mode = always        → send success OR failure
#
# Required repo vars: PIPEPUSH_SERVER, PIPEPUSH_TOKEN.
# For the error tail: the step writes pipe.log (see bitbucket-pipelines.yml,
#   analyze-and-test + build web). If it is missing, it stays link-only.
#
# EVERYTHING here is deliberately non-fatal: an after-script must never turn the
# build red. Every sub-operation falls back silently to "less information".

set -u

PIPELINE="${1:?pipeline name required}"
MODE="${2:-always}"

EXIT_CODE="${BITBUCKET_EXIT_CODE:-0}"
# failure-only: on success send nothing at all (success is reported by a later
# step).
if [ "$MODE" = "failure-only" ] && [ "$EXIT_CODE" = "0" ]; then
  exit 0
fi
if [ "$EXIT_CODE" = "0" ]; then STATUS="success"; else STATUS="failure"; fi

WS="${BITBUCKET_WORKSPACE:-}"
REPO="${BITBUCKET_REPO_SLUG:-}"
BUILD="${BITBUCKET_BUILD_NUMBER:-}"
LOG_URL="https://bitbucket.org/${WS}/${REPO}/pipelines/results/${BUILD}"

# --- Error tail from the local pipe.log (best effort, on failure only)
# --------- Steps that want the tail tee their output to
# $BITBUCKET_CLONE_DIR/pipe.log.
TAIL=""
LOGFILE="${BITBUCKET_CLONE_DIR:-.}/pipe.log"
if [ "$STATUS" = "failure" ] && [ -s "$LOGFILE" ]; then
  ESC=$(printf '\033')
  # Strip ANSI colour codes, strip control characters (except tab/newline), drop
  # blank lines, take the last 15 lines, cap hard at 3000 characters (keep the
  # message short).
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
