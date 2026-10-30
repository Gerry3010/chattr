#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Does the gitleaks allowlist still catch a REAL secret?
#
# `.gitleaks.toml` silences 41 verified-benign findings. The danger of any
# allowlist is that it grows a little too wide and then silences everything —
# and nobody notices, because a scan that finds nothing looks exactly like a
# clean repository. So this plants secrets that MUST be found and fails if they
# are not.
#
# Deliberately placed in lib/ and test/ — the two directories the allowlist
# touches with its storage-key-name and fixture exceptions. A guard that only
# tests an untouched directory proves nothing.
#
#   scripts/ci/gitleaks-selftest.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

GITLEAKS="${GITLEAKS:-docker run --rm -v PWD:/repo -w /repo zricethezav/gitleaks:latest}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp .gitleaks.toml "$tmp/"
mkdir -p "$tmp/lib" "$tmp/test"

# 1. Tokens whose rules the allowlist does not touch at all.
#    NOT the canonical AWS example key (AKIAIOSFODNN7EXAMPLE) — gitleaks
#    filters that one itself, so it would prove nothing. The first attempt used
#    it and reported "0 found", which looked like a far too wide allowlist and
#    was a badly chosen plant.
#
#    The tokens are GENERATED here, never written into this file: GitHub's push
#    protection rejected the commit when they stood as literals (2026-09-13,
#    "push declined due to repository rule violations"). It was right to — a
#    string that looks enough like a credential to be scanned for is one that
#    does not belong in a repository, even as a test fixture. Generating them
#    also makes the plant stronger: every run uses a fresh value, so nothing can
#    creep into an allowlist by accident.
zufall() { head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
{
  printf 'const ghToken = "%s_%s";\n' 'ghp' "$(zufall 36)"
  printf 'const slack = "%s-%s-%s-%s";\n' 'xoxb' \
    "$(zufall 12 | tr -dc '0-9')2847294819" "$(zufall 12 | tr -dc '0-9')2847294819" \
    "$(zufall 24)"
} > "$tmp/lib/leak_a.dart"

# 2. A JWT from a REAL project, beside the demo token that IS allowlisted.
#    This is the exception most likely to be drawn too wide: it has to pin the
#    payload `{"iss":"supabase-demo"`, not the shape of a JWT. Both tokens sit
#    in one file on purpose — the scan has to separate them.
python3 - "$tmp/test/leak_b.dart" <<'PY'
import base64, json, sys
def b64(o): return base64.urlsafe_b64encode(
    json.dumps(o, separators=(',', ':')).encode()).decode().rstrip('=')
h = b64({"alg": "HS256", "typ": "JWT"})
real = b64({"iss": "https://real-project.supabase.co",
            "role": "service_role", "exp": 1983812996})
demo = b64({"iss": "supabase-demo", "role": "anon", "exp": 1983812996})
sig = "Xk9pQm2LvNrT8sYbWcZdQeRfGhJkLmNoPqRsTuVwXyZ"
open(sys.argv[1], "w").write(
    f'const realToken = "{h}.{real}.{sig}";\n'
    f'const demoToken = "{h}.{demo}.{sig}";\n')
PY

cd "$tmp"
out="$tmp/report.json"
# Der Bericht muss IN DEN GEMOUNTETEN Pfad geschrieben werden. Beim ersten
# Anlauf stand hier der Host-Pfad — gitleaks legte ihn im Container ab, auf der
# Platte kam nie eine Datei an, und der Test meldete "0 Funde": ein zu weiter
# Filter und ein kaputter Messaufbau sehen von hier aus gleich aus.
${GITLEAKS/PWD/$PWD} detect --no-git --config /repo/.gitleaks.toml \
  --report-format json --report-path /repo/report.json >/dev/null 2>&1 || true
[ -s "$out" ] || { echo "✗ Kein Bericht entstanden — der Messaufbau ist kaputt, nicht die Liste."; exit 1; }

gefunden=$(python3 -c "import json,sys;print(len(json.load(open('$out'))))" 2>/dev/null || echo 0)
dateien=$(python3 -c "
import json
print(' '.join(sorted({f['File'] for f in json.load(open('$out'))})))" 2>/dev/null || echo '')

if [ "$gefunden" -lt 3 ]; then
  echo "✗ Die Ausnahmeliste ist ZU WEIT: nur $gefunden von 3 gepflanzten Geheimnissen gefunden."
  echo "  gefunden in: ${dateien:-nichts}"
  exit 1
fi
echo "✓ Alle 3 gepflanzten Geheimnisse gefunden ($gefunden Treffer) — die Liste ist eng genug."
