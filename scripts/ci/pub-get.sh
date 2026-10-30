#!/usr/bin/env bash
# `flutter pub get` for the pipeline — with the two precautions it needs so that
# four forked packages from GitHub do not endanger every run.
#
# Why this exists as a script and not four times inline: exactly these lines
# stood in four places in `bitbucket-pipelines.yml` (analysis, web staging, web
# prod, APK). When the first of them went red on 2026-09-02, the other three
# would have fallen the same way at the next tag — repairing one copy would only
# have moved the fault.
set -euo pipefail

# ── 0. Flutter version from .flutter-version (CHAT-47) ─────────────────────
# The CI image is cirruslabs/flutter:3.44.0, and cirruslabs publishes no newer
# image (last one 2026-05-20). 3.47.8 brings a TLS fix in dart:io on Android
# and a libpng update in the engine, so the SDK inside the image is switched
# here, in the one script every Flutter step already calls. The SDK in the
# image is a git checkout; a tag fetch is a few MB.
want="$(tr -d '[:space:]' < .flutter-version 2>/dev/null || true)"
if [ -n "$want" ]; then
  have="$(flutter --version 2>/dev/null | head -1 | awk '{print $2}')"
  if [ "$have" != "$want" ]; then
    sdk="$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")"
    git config --global --add safe.directory "$sdk"
    git -C "$sdk" fetch --depth 1 origin tag "$want"
    git -C "$sdk" checkout -q -f "$want"
    flutter --version
  fi
fi

# ── 1. Force git protocol 0 ────────────────────────────────────────────────
# GitHub rejects the SECOND call of protocol 2 (`POST …/git-upload-pack`) for
# anonymous clones from the runner's IP with 401; the reference list before it
# comes back 200. git reports that as fatal: could not read Username for
# 'https://github.com' which looks like a private repo and is none — the repos
# are public and reachable from any other machine. With protocol 0 the
# references are already in the first response, and the rejected call does not
# happen. (Reproduced in the build container on nc-deploy on 2026-09-02: v2 401,
# v0 green.)
git config --global protocol.version 0

# ── 2. Throw the git cache away only when it cannot serve the lock ─────────
# The `flutter-pub` cache holds the git dependencies. If a fork TAG moves, pub
# used to keep the old checkout and read the fork's pubspec from the old commit
# — whose transitive dependencies (emoji_picker_flutter, any_link_preview, …)
# silently fell away, and package_graph.json became contradictory ("dependencies
# for X missing"). So for a long time it was thrown away on EVERY run, which
# cost four GitHub clones per run and ran into the rate limit.
#
# What is asked now is what matters: **is there a checkout in the cache for
# every commit pinned in `pubspec.lock`?** Yes → the cache serves the lock
# completely, pub does not need GitHub at all. No → it no longer fits, and then
# we clear it away.
#
# Why by COMMIT and not by package name: pub names the directory after the REPO,
# not after the package — `share_handler_ios` lies under
# `share_handler-<commit>`. A package→repo mapping would be a second list that
# goes stale; the commit is the same string in both worlds.
#
# And why no remembered checksum (the first attempt, discarded): Bitbucket does
# NOT re-upload a cache that already exists ("Skipping upload for existing
# cache") — a marker in the cache therefore never survives the step, and the
# check stood permanently at "unknown". This one needs nothing that outlives a
# run.
fehlend=0
while read -r ref; do
  [ -n "$ref" ] || continue
  # `*-<commit>` statt `<paket>-<commit>`: siehe oben.
  if ! compgen -G "$HOME/.pub-cache/git/*-$ref" > /dev/null; then
    echo "pub-get: kein Auszug fuer $ref im Cache"
    fehlend=$((fehlend + 1))
  fi
done <<< "$(sed -n 's/.*resolved-ref: *"\?\([0-9a-f]\{7,40\}\)"\?.*/\1/p' pubspec.lock)"

if [ "$fehlend" -gt 0 ]; then
  echo "pub-get: $fehlend Bezug/Bezuege fehlen — Git-Cache wird abgeraeumt und neu geholt"
  rm -rf "$HOME/.pub-cache/git"
else
  echo "pub-get: der Cache bedient den Lock vollstaendig — kein GitHub noetig"
fi

# The .dart_tool manifests are regenerable and cheap — those go regardless, so
# the graph is rebuilt cleanly.
rm -rf .dart_tool/package_graph.json .dart_tool/package_config.json

# ── 3. Several attempts with a growing pause ───────────────────────────────
# The rate limit bites on VOLUME, not on protocol: on the first attempt three of
# the four forks got through, the fourth got a 401. So nothing is permanently
# broken, it is too much at once — and waiting helps against that.
#
# The cache alone is NOT the answer, because it solves the problem only when it
# is filled: Bitbucket does not even upload it for a failed step ("Skipping
# cache upload for failed step"). Without a first successful run every run
# clones all four again — chicken and egg. This loop breaks that; afterwards the
# cache carries it. Few attempts with a long pause rather than many short ones:
# EVERY attempt clones four repos in its own right, so four attempts were up to
# sixteen requests — that fed the limit rather than waiting it out.
versuche=2
pause=90
for n in $(seq 1 "$versuche"); do
  if flutter pub get; then
    break
  fi
  if [ "$n" -eq "$versuche" ]; then
    echo "pub-get: nach $versuche Anlaeufen aufgegeben" >&2
    exit 1
  fi
  echo "pub-get: Versuch $n gescheitert — $pause s warten (GitHub-Ratenlimit?)" >&2
  # Clear away half-fetched clones: pub leaves remnants in _temp on an abort,
  # and a second attempt should start on clean ground.
  rm -rf "$HOME/.pub-cache/_temp"
  sleep "$pause"
  pause=$((pause * 2))
done
