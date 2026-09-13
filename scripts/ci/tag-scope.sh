#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What is this release tag actually supposed to deliver?
#
# Since 1.27 a tag triggers the deployment, no longer a push to `main`. A suffix
# on the tag narrows WHAT is delivered — that saves the expensive steps when
# only part of it is affected (an APK build costs minutes, a migration seconds).
#
# v1.27.0 everything: web + landing + server + APK v1.5.5-server server
# (supabase/) + web + landing, NO APK v1.27.0-apk the Android APK only
#
# A `-web` of its own deliberately does NOT exist (Gerry, 2026-08-28): it is
# inside `-server`, and the only case it would cover alone — landing only or web
# client only — runs with `-server` just the same. The migrations run into
# nothing when there are no new ones, and they do that on every deploy anyway.
# Three forms one can remember are better than four, two of which overlap.
#
# **Why the evaluation lives here and not in `pipelines.tags`.** A tag
# `v1.27.0-server` also matches the pattern `v*`. Which of two matching patterns
# Bitbucket takes depends on its ordering semantics — and basing a prod
# deployment on that means relying on something one has not tested and that can
# change. So there is EXACTLY ONE tag pipeline, and every step asks here whether
# it is meant. That makes it irrelevant which pattern matched.
#
# Use in a pipeline step: source scripts/ci/tag-scope.sh scope_includes apk || {
# echo "Not in the scope of $BITBUCKET_TAG"; exit 0; }

# The component this tag concerns: full | server | web | apk
tag_scope() {
  case "${1:-$BITBUCKET_TAG}" in
    *-server) echo server ;;
    *-apk)    echo apk ;;
    *)        echo full ;;
  esac
}

# Is `web` / `server` / `apk` included in this tag?
#
# `-server` explicitly pulls the web along (Gerry, 2026-08-28): a backend that
# changes generally needs the client that matches it — and the web client is
# delivered from the same host anyway. The landing hangs on the web; it is
# static content on the same route.
scope_includes() {
  local scope; scope="$(tag_scope)"
  case "$scope:$1" in
    full:*)         return 0 ;;
    server:web)     return 0 ;;
    server:server)  return 0 ;;
    apk:apk)        return 0 ;;
    *)              return 1 ;;
  esac
}

# Which version line from version.json has to match the tag?
#
# A pure server release bumps `backend_version`, not `app_version` — the tag
# then carries that number. Everything else hangs on the app version, because
# that is the number the user sees.
tag_version_field() {
  case "$(tag_scope)" in
    server) echo backend_version ;;
    *)      echo app_version ;;
  esac
}

# The tag without a suffix — the bare version number with a leading `v`.
tag_version_part() {
  local t="${1:-$BITBUCKET_TAG}"
  echo "${t%-server}" | sed -E 's/-apk$//'
}
