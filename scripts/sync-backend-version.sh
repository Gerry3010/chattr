#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Sync the backend version from version.json (the single source of truth) into
# the prod table app_versions — THE source clients query via
# get_backend_version(). Has to run after every migration apply on prod,
# otherwise the server-reported version drifts (it stood at 1.0.0 since April).
#
# ./scripts/sync-backend-version.sh
#
# Creates one row per component (backend/migrations/database) with the current
# backend_version (the history stays; UNIQUE(component, version) makes a re-run
# idempotent).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# Backend host kept OUT of the public repo (see scripts/.deploy-hosts.env.example).
[ -f "$SCRIPT_DIR/.deploy-hosts.env" ] && . "$SCRIPT_DIR/.deploy-hosts.env"
SERVER="${CHATTR_BACKEND_SSH:?set CHATTR_BACKEND_SSH or scripts/.deploy-hosts.env}"

BACKEND_VERSION=$(jq -r '.backend_version' "$PROJECT_ROOT/version.json")
LATEST_MIGRATION=$(ls "$PROJECT_ROOT/supabase/migrations" | grep -E '^[0-9]{5}_' | sort | tail -1)

echo "→ Sync backend v$BACKEND_VERSION (bis $LATEST_MIGRATION) nach app_versions …"

ssh "$SERVER" "docker exec -i supabase-db psql -U postgres -d postgres -tA" <<SQL
INSERT INTO app_versions (component, version, description, deployed_by)
VALUES
  ('backend',    '$BACKEND_VERSION', 'Synced from version.json (migrations up to $LATEST_MIGRATION)', 'sync-backend-version.sh'),
  ('migrations', '$BACKEND_VERSION', '$LATEST_MIGRATION', 'sync-backend-version.sh'),
  ('database',   '$BACKEND_VERSION', 'Schema version $BACKEND_VERSION', 'sync-backend-version.sh')
ON CONFLICT (component, version) DO UPDATE
  SET deployed_at = NOW(), description = EXCLUDED.description;
SELECT component, version, deployed_at::date FROM app_versions
WHERE version = '$BACKEND_VERSION' ORDER BY component;
SQL

echo "→ Verifikation via get_backend_version():"
ssh "$SERVER" "docker exec -i supabase-db psql -U postgres -d postgres -tA -c \"SELECT * FROM get_backend_version()\""
