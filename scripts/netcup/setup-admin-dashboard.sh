#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Helper for standing up admin.chattr.geraldhofbauer.net on the netcup box.
# Run ON the box. It (1) generates the basic_auth bcrypt hash, (2) fills it into
# the Caddy site block, and (3) prints the exact reload steps. It does NOT blindly
# edit the live Caddyfile — placement depends on your Caddy layout, so it hands
# you a ready-to-import file and tells you what to do.
#
# mTLS is a CONFIG TOGGLE (default require here for Gerry's prod; OSS can turn off):
#   ADMIN_MTLS=require ./setup-admin-dashboard.sh   # keep the client-cert gate (default)
#   ADMIN_MTLS=off     ./setup-admin-dashboard.sh   # basic_auth only (strips the tls block)
#
# Usage:  ./setup-admin-dashboard.sh [admin-username]
set -euo pipefail

USER_NAME="${1:-admin}"
ADMIN_MTLS="${ADMIN_MTLS:-require}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$HERE/caddy/admin.chattr.geraldhofbauer.net.Caddyfile"
OUT="/tmp/admin.chattr.geraldhofbauer.net.Caddyfile"

command -v caddy >/dev/null || { echo "caddy not found in PATH"; exit 1; }
[ -f "$TEMPLATE" ] || { echo "template not found: $TEMPLATE"; exit 1; }

echo "Admin console basic_auth for user '$USER_NAME' (mTLS: $ADMIN_MTLS)."
read -r -s -p "Choose a strong password: " PW; echo
[ -n "$PW" ] || { echo "empty password"; exit 1; }

HASH="$(caddy hash-password --plaintext "$PW")"
unset PW

sed -e "s|admin REPLACE_WITH_BCRYPT_HASH|$USER_NAME $HASH|" \
    -e "s|# admin  <bcrypt-hash>|# $USER_NAME  (bcrypt below)|" \
    "$TEMPLATE" > "$OUT"

# Strip the mTLS block (between the >>> / <<< markers) unless required.
if [ "$ADMIN_MTLS" != "require" ]; then
  sed -i '/# >>> mTLS/,/# <<< mTLS/d' "$OUT"
  echo "mTLS: OFF — removed the client_auth block (basic_auth only)."
else
  echo "mTLS: REQUIRED — keep the CA at /home/chattr/chattr-admin-ca.crt."
fi

echo
echo "Wrote site block → $OUT"
echo
echo "Next:"
echo "  1. Add it to Caddy (pick what matches your setup):"
echo "       import $OUT        # if your Caddyfile uses import"
echo "     or append its contents to your main Caddyfile."
echo "  2. Validate + reload:"
echo "       caddy validate --config /etc/caddy/Caddyfile"
echo "       systemctl reload caddy   # or: caddy reload --config /etc/caddy/Caddyfile"
echo "  3. Ensure DNS: admin.chattr.geraldhofbauer.net  A  <prod-host>"
echo
echo "This site only reverse-proxies to the admin-proxy sidecar (127.0.0.1:8899)"
echo "in the Supabase compose stack — it serves the panel AND injects the secret."
echo "The API secret (ADMIN_STATS_SECRET) is a pipeline var; the deploy writes it"
echo "into the stack .env so both the functions and admin-proxy containers read it."
echo "Bring the sidecar up with: docker compose up -d admin-proxy. See docs/ADMIN_DASHBOARD.md."
