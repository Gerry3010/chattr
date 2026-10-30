#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Checks that `backend_migration` in version.json names the highest migration
# under supabase/migrations/.
#
# WHAT FOR. `backend_version` is the number a `-server` tag has to carry. It was
# set to 1.5.4 on 2026-08-13 and stayed there — while NINE migrations were added
# (00074 … 00083), among them the private avatar stores and the chat requests. A
# `-server` tag would afterwards have claimed a version under which the shipped
# state cannot be found again later. And nobody would have noticed: when only
# care is missing, nothing falls over.
#
# The field `backend_migration` turns that into a hard stop at exactly the
# moment it happens — whoever adds a migration MUST touch version.json, and
# `backend_version` stands in the line above it there.
#
# Honestly: what is enforced is the touching, not the height of the number.
# Whoever adds `backend_migration` and leaves `backend_version` alone gets
# through. That is deliberate — no script can decide whether a migration is
# worth a patch or a minor step. The silent drift over months that happened here
# is nevertheless ruled out.
set -euo pipefail

cd "$(dirname "$0")/../.."

hoechste="$(ls supabase/migrations/ \
  | sed -nE 's/^([0-9]{5})_.*\.sql$/\1/p' \
  | sort | tail -1)"

if [[ -z "$hoechste" ]]; then
  echo "✗ Keine Migration gefunden — liest dieses Skript noch, was es soll?"
  exit 1
fi

vermerkt="$(python3 -c "import json;print(json.load(open('version.json')).get('backend_migration',''))")"
version="$(python3 -c "import json;print(json.load(open('version.json'))['backend_version'])")"

if [[ -z "$vermerkt" ]]; then
  echo "✗ version.json hat kein Feld 'backend_migration'."
  echo "   → \"backend_migration\": \"$hoechste\" ergaenzen."
  exit 1
fi

if [[ "$vermerkt" != "$hoechste" ]]; then
  echo "✗ Neue Migration(en) ohne Eintrag: hoechste ist $hoechste,"
  echo "  version.json vermerkt $vermerkt (backend_version $version)."
  echo "   → version.json nachziehen: backend_migration auf $hoechste,"
  echo "     und dabei entscheiden, ob backend_version steigen muss"
  echo "     (./scripts/bump-version.sh --component backend --type patch|minor)."
  exit 1
fi

echo "✓ backend_version $version deckt Migrationen bis $hoechste"
