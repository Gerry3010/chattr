#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later

#
# chatview-fork-sync.sh — chattr-side integration half of the fork auto-sync.
#
# The REBASE half now lives in GitHub Actions on the forks (Gerry3010/chatview
# and Gerry3010/chatview_utils, workflow "chattr fork sync"): weekly they rebase
# our patches onto new upstream releases, validate the package, and push a
# `chattr-<version>` tag. This script — run weekly by a user crontab AFTER the
# Actions — notices such a new tag, tests that chattr still builds against it,
# and opens a chattr PR bumping the dependency_overrides ref. It notifies via
# pipepush on success / test failure; silent when there's nothing newer.
# It NEVER auto-deploys chattr (merge stays with Gerry) and never rebases the
# forks (that's the GitHub Actions' job).
#
# Env knobs: DRY_RUN=1 (detect + test, never push/PR).
set -uo pipefail

CHATTR_DIR="${CHATTR_DIR:-/home/gerry/Sync-Projekte/Chattr2/chattr}"
TOKEN_FILE="${PIPEPUSH_TOKEN_FILE:-$HOME/.config/chattr-fork-sync/token}"
PIPELINE="chattr-fork-sync"
export PIPEPUSH_SERVER="${PIPEPUSH_SERVER:-https://pipepush.geraldhofbauer.net}"
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/flutter/bin:$HOME/go/bin:$HOME/.claude/scripts:$PATH"
DRY_RUN="${DRY_RUN:-0}"

PKGS=(chatview chatview_utils)
declare -A FORK_URL=(
  [chatview]="https://github.com/Gerry3010/chatview.git"
  [chatview_utils]="https://github.com/Gerry3010/chatview_utils.git"
)

LOGDIR="$HOME/.local/state/chattr-fork-sync"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/sync-$(date +%Y%m%dT%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date +%H:%M:%S)] $*"; }
notify() { # <status> <message...>
  local status="$1"; shift
  log "NOTIFY [$status] $*"
  if [[ -r "$TOKEN_FILE" ]]; then
    PIPEPUSH_TOKEN="$(cat "$TOKEN_FILE")" pipepush send \
      --status "$status" --pipeline "$PIPELINE" --message "$*" >/dev/null 2>&1 \
      || log "WARN: pipepush send failed"
  else
    log "WARN: no token at $TOKEN_FILE — notification skipped"
  fi
}
# highest x.y.z among `chattr-x.y.z` tags on stdin (Actions style; ignores -pN)
highest_chattr_ver() {
  sed -nE 's/^chattr-([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}
ver_gt() { [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" == "$1" ]]; }
# version embedded in chattr's pubspec ref for a package (chattr-3.1.0-p2 -> 3.1.0)
cur_ref_ver() { # <pkg>
  awk -v p="  $1:" '
    $0==p {f=1}
    f && /ref:/ {print; exit}
  ' "$CHATTR_DIR/pubspec.yaml" | sed -nE 's/.*chattr-([0-9]+\.[0-9]+\.[0-9]+).*/\1/p'
}

command -v flutter >/dev/null || { notify failure "flutter not on PATH in cron env"; exit 1; }

# Rewrite the git `ref:` of the advanced package(s) in a pubspec.yaml in place.
# (Non-advanced packages keep their current ref — we must NOT drop their fork
# override, or they'd resolve to the upstream/hosted version.)
bump_refs() { # <pubspec_path>
  python3 - "$1" "$(for p in "${!TARGET[@]}"; do echo -n "$p=${TARGET[$p]} "; done)" <<'PY'
import re, sys
path = sys.argv[1]
tags = dict(a.split('=', 1) for a in sys.argv[2].split())
lines = open(path).read().split('\n')
cur = None
for i, l in enumerate(lines):
    m = re.match(r'^  ([\w-]+):\s*$', l)
    if m:
        cur = m.group(1)
    if cur in tags and re.match(r'^\s+ref:', l):
        lines[i] = re.sub(r'chattr-\S+', tags[cur], l)
        cur = None
open(path, 'w').write('\n'.join(lines))
PY
}

# --- 1. detect forks whose Actions produced a newer chattr-<version> tag ------
declare -A TARGET   # pkg -> chattr-<version> tag to move to
n_updates=0
for pkg in "${PKGS[@]}"; do
  newest="$(git ls-remote --tags "${FORK_URL[$pkg]}" 2>/dev/null \
    | sed -E 's#.*refs/tags/##; s/\^\{\}$//' | highest_chattr_ver)"
  cur="$(cur_ref_ver "$pkg")"
  log "$pkg: newest fork tag=${newest:-none}  chattr ref version=${cur:-?}"
  if [[ -n "$newest" && -n "$cur" ]] && ver_gt "$newest" "$cur"; then
    TARGET[$pkg]="chattr-$newest"
    n_updates=$((n_updates + 1))
  fi
done
if [[ $n_updates -eq 0 ]]; then log "chattr already on the newest fork tags — nothing to do"; exit 0; fi
log "updates available: $(for p in "${!TARGET[@]}"; do echo -n "$p->${TARGET[$p]} "; done)"

# --- 2. test chattr against the new tag(s) via a git override (matches prod) --
WT="$(mktemp -d)"
cleanup() { git -C "$CHATTR_DIR" worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$WT"; }
trap cleanup EXIT
git -C "$CHATTR_DIR" worktree add -q --detach "$WT" HEAD
cp "$CHATTR_DIR/.env" "$WT/.env" 2>/dev/null || cp "$CHATTR_DIR/.env.example" "$WT/.env" 2>/dev/null || true
# Bump the advanced package(s)' ref directly in the worktree's pubspec.yaml —
# exactly what the PR will do, and keeps every other fork override intact
# (a pubspec_overrides.yaml would REPLACE the whole overrides block, dropping
# the non-advanced package's fork override → it'd resolve to upstream).
bump_refs "$WT/pubspec.yaml"

TEST_OK=1
( cd "$WT"
  if ! flutter pub get >/dev/null 2>&1; then
    echo "pub get failed — attempting flutter pub upgrade --major-versions"
    flutter pub upgrade --major-versions >/dev/null 2>&1 || true
    flutter pub get >/dev/null 2>&1 || exit 10
  fi
  flutter analyze >/dev/null 2>&1 || exit 11
  flutter test >/dev/null 2>&1 || exit 12
) || TEST_OK=0

VER_LABEL="$(for p in "${!TARGET[@]}"; do echo -n "$p ${TARGET[$p]}; "; done)"
if [[ $TEST_OK != 1 ]]; then
  notify failure "new fork tag(s) [$VER_LABEL] but chattr build FAILED (pub get/analyze/test) — needs attention"
  exit 1
fi
log "chattr green against new fork tag(s)"

if [[ "$DRY_RUN" == "1" ]]; then log "DRY_RUN=1 — validated, not opening a PR"; exit 0; fi

# --- 3. open a chattr PR bumping the override ref(s) --------------------------
cd "$CHATTR_DIR"
BR="chore/chatview-sync-$(printf '%s' "${TARGET[chatview]:-${TARGET[chatview_utils]}}" | sed 's/chattr-//')"
git fetch -q origin main
git checkout -q -B "$BR" origin/main
bump_refs pubspec.yaml
if flutter pub get >/dev/null 2>&1 && git add pubspec.yaml pubspec.lock &&
   git -c user.name='Gerry' -c user.email='geraldhofbauer9@gmail.com' \
     commit -q -m "chore(chatview): bump fork ref(s) — $VER_LABEL"; then
  git push -qf origin "$BR"
  PR_MSG="opened"
  YES=1 bb pr-create "$BR" main \
    --title "chore(chatview): sync fork ref(s) — $VER_LABEL" \
    --desc "Automated by chatview-fork-sync (chattr side). GitHub Actions rebased the fork patches onto new upstream; this bumps chattr's override ref(s). chattr analyze+test green. Review + merge." \
    >/dev/null 2>&1 || PR_MSG="branch pushed (open PR manually)"
  notify success "chatview fork(s) synced ✅ [$VER_LABEL] chattr green, PR $PR_MSG ($BR)"
else
  notify failure "new fork tag(s) [$VER_LABEL] green in test, but the chattr ref-bump branch failed — bump pubspec manually"
fi
git checkout -q main 2>/dev/null || true
log "done"
