#!/usr/bin/env bash
# Run all backend regression tests against the local Supabase stack:
#   - *.sql RLS/function tests via psql (each documents its expected
#     `key=N` output lines, see its header)
#   - the Deno edge-function authorization tests (skipped if deno is absent)
#
#   ./supabase/tests/run.sh
#
# Override the connection with PGURL if needed.
set -euo pipefail

PGURL="${PGURL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

status=0
for f in "$DIR"/*.sql; do
  echo "── $(basename "$f")"
  if ! out=$(psql "$PGURL" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1); then
    echo "$out"
    echo "   ✗ FAILED (sql error)"
    status=1
    continue
  fi
  echo "$out" | grep -E '=[0-9]+$' | sed 's/^/   /'
done

# Edge-function authorization tests (Deno). Verifies both privileged,
# RLS-bypassing functions reject non-service-role callers with 401.
FUNC_TESTS="$DIR/../functions/tests"
if command -v deno >/dev/null 2>&1; then
  echo "── edge-function auth (deno)"
  # --allow-read: admin_dashboard_timeline_test.ts liest landing/admin/index.html
  if deno test --allow-read --allow-env --allow-net --no-check --quiet "$FUNC_TESTS"/; then
    echo "   ✓ ok"
  else
    echo "   ✗ FAILED (deno tests)"
    status=1
  fi
else
  echo "── edge-function auth (deno)  ⏭  skipped (deno not installed)"
fi

exit $status
