#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Checks that every git override in pubspec.yaml still points at EXACTLY the
# commit pubspec.lock records as `resolved-ref`.
#
# WHAT FOR. We pin the chatview forks to a **tag** (`chattr-3.1.0-pN`), and a
# tag is movable — the forks' sync workflow sets some anew with `git tag -f`
# itself. If somebody moved a patch tag, CI would go on green (the lock holds
# the old commit, after all), but pubspec.yaml and pubspec.lock would tell two
# different stories from then on: the next `pub upgrade` — or a fresh clone
# without the lock — would silently pull in different code. This step catches
# exactly that divergence, and at the only place where it is still cheap.
#
# Deliberately NO switch to commit hashes: one would then no longer see from the
# pubspec which patch state is in there, and `chatview-fork-sync.sh` reads the
# version out of the ref name.
set -euo pipefail

cd "$(dirname "$0")/../.."

fehler=0

# Read every git override from the lock: package, URL, ref, resolved commit. The
# lock is the more reliable source — it names both side by side.
python3 - <<'PY' > /tmp/fork-refs.$$ || exit 1
import re, sys
lock = open('pubspec.lock', encoding='utf-8').read()
# Bloecke der Form:  name:\n    dependency: ...\n    description:\n      ...
muster = re.compile(
    r'^  (?P<name>[\w_]+):\n'
    r'(?:    .*\n|      .*\n)*?'
    r'    source: git\n', re.M)
for m in muster.finditer(lock):
    block = m.group(0)
    def feld(f):
        t = re.search(rf'^      {f}: "?([^"\n]+)"?$', block, re.M)
        return t.group(1) if t else None
    ref, sha, url = feld('ref'), feld('resolved-ref'), feld('url')
    if ref and sha and url:
        print(f"{m.group('name')}\t{url}\t{ref}\t{sha}")
PY

anzahl=0
while IFS=$'\t' read -r name url ref sha; do
  [[ -n "$name" ]] || continue
  anzahl=$((anzahl + 1))
  # With an annotated tag, `^{}` is the commit; the bare entry points at the tag
  # object. Whoever reads only the bare one compares apples with oranges.
  entfernt="$(git ls-remote "$url" "refs/tags/$ref^{}" "refs/tags/$ref" "refs/heads/$ref" 2>/dev/null \
    | awk '{print $1"\t"$2}' | sort -k2 | tail -1 | cut -f1)"
  if [[ -z "$entfernt" ]]; then
    echo "✗ $name: Ref '$ref' gibt es bei $url nicht (mehr)"
    fehler=1
    continue
  fi
  if [[ "$entfernt" != "$sha" ]]; then
    echo "✗ $name: '$ref' zeigt jetzt auf ${entfernt:0:12}, die Lock haelt ${sha:0:12}"
    echo "   → Der Ref ist gewandert. Bei einem Tag heisst das, dass ihn jemand"
    echo "     verschoben hat (zurechtruecken oder die Lock nachziehen); bei"
    echo "     einem Branch-Ref ist Wandern normal — dann gehoert die Lock"
    echo "     nachgezogen: flutter pub upgrade $name"
    fehler=1
  else
    echo "✓ $name: $ref → ${sha:0:12}"
  fi
done < /tmp/fork-refs.$$
rm -f /tmp/fork-refs.$$

if [[ $anzahl -eq 0 ]]; then
  echo "✗ Kein Git-Override in pubspec.lock gefunden — liest dieses Skript noch,"
  echo "  was es lesen soll? (Ein Waechter, der nichts prueft, ist keiner.)"
  exit 1
fi

exit $fehler
