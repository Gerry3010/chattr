#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later

#
# make-staging-compose.sh — derive a staging-isolated docker-compose.yml from
# the production Supabase compose, so a staging stack can run on the SAME
# Docker engine as prod WITHOUT colliding on container names or host ports.
#
# The prod compose uses fixed `container_name:` values (supabase-kong, …) and
# publishes ports. On a shared engine Docker refuses to start a second stack
# with the same names/ports (prod stays untouched, but staging won't come up).
# This transform:
#   • prefixes every container_name with "staging-"
#   • rebinds every PUBLISHED port to 127.0.0.1 on a distinct staging range
#     (internal ports are left alone — internal DB URLs use POSTGRES_PORT=5432)
#
# Usage:  scripts/staging/make-staging-compose.sh [src-compose] > staging-compose.yml
# Default src: supabase/docker-compose.yml (run from repo root).
#
# Staging published host ports (127.0.0.1 only; host-nginx proxies staging-api):
#   kong  http 8110 (→8000)   https 8153 (→8443)
#   db    5532 (→5432)        pooler 6643 (→6543)
#   analytics 4110 (→4000)
# (8100 was already in use on the box, hence 8110/8153/4110 — verified free.)
set -euo pipefail
SRC="${1:-supabase/docker-compose.yml}"
[ -f "$SRC" ] || { echo "compose not found: $SRC" >&2; exit 1; }

sed -E \
  -e 's|^(    container_name: )([^[:space:]]+)|\1staging-\2|' \
  -e 's|^(      - )\$\{KONG_HTTP_PORT\}:8000/tcp|\1127.0.0.1:8110:8000/tcp|' \
  -e 's|^(      - )\$\{KONG_HTTPS_PORT\}:8443/tcp|\1127.0.0.1:8153:8443/tcp|' \
  -e 's|^(      - )\$\{POSTGRES_PORT\}:5432|\1127.0.0.1:5532:5432|' \
  -e 's|^(      - )\$\{POOLER_PROXY_PORT_TRANSACTION\}:6543|\1127.0.0.1:6643:6543|' \
  -e 's|^(      - )4000:4000|\1127.0.0.1:4110:4000|' \
  "$SRC"
