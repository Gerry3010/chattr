#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Adds the missing security headers to the host Caddy on nc-chattr.
#
# OCCASION: the weekly ZAP scan reports them as medium findings, measured
# against staging. Verified on 2026-08-21: chattr.at, app.chattr… AND staging-
# app send NOT ONE of them — so the finding applies to prod.
#
# WHY THIS WEIGHS MORE HERE THAN ON AN ORDINARY SITE: the web app decrypts
# messages IN THE BROWSER. Whoever can execute foreign code there reads
# plaintext and keys — not ciphertext. These headers are the second line of
# defence for exactly that case.
#
# DELIBERATELY NOT INCLUDED: Content-Security-Policy. Flutter Web needs 'wasm-
# unsafe-eval', blob workers and the service worker; too narrow a policy yields
# a white screen rather than an error message. That belongs tested through
# staging and comes as a step of its own.
#
# IDEMPOTENCY PER SITE BLOCK, not file-wide. The first draft checked with a
# `grep X-Frame-Options` over the whole file — and aborted, because
# admin.chattr… has the header already. "Already there" was reported, nothing
# was ever touched. A guard that trips on a FOREIGN block is worse than none: it
# reports success.
#
# Run ON THE SERVER (nc-chattr), directly there: sudo bash ~/add-security-
# headers.sh
set -euo pipefail

CADDYFILE=/etc/caddy/Caddyfile
STAMP=$(date +%Y%m%d-%H%M%S)
SICHERUNG="$CADDYFILE.bak-sechdr-$STAMP"

[ -f "$CADDYFILE" ] || { echo "FEHLER: $CADDYFILE fehlt — laeuft das hier auf nc-chattr?"; exit 1; }
cp -a "$CADDYFILE" "$SICHERUNG"
echo "Sicherung: $SICHERUNG"

echo "--- Site-Bloecke ---"
set +e
python3 - "$CADDYFILE" <<'PY'
import sys

pfad = sys.argv[1]
zeilen = open(pfad).read().split("\n")

BLOCK = """\t# Sicherheits-Kopfzeilen (2026-08-21, ZAP-Funde aus dem woechentlichen Scan).
\t# max-age bewusst 6 Monate und OHNE preload: Ein Fehler altert von selbst aus,
\t# ein Preload-Eintrag nicht — der ist praktisch unumkehrbar.
\theader {
\t\tStrict-Transport-Security "max-age=15768000; includeSubDomains"
\t\tX-Content-Type-Options "nosniff"
\t\tX-Frame-Options "DENY"
\t\tReferrer-Policy "no-referrer"
\t\tPermissions-Policy "geolocation=(), microphone=(), camera=(), payment=(), usb=()"
\t\tCross-Origin-Opener-Policy "same-origin"
\t}""".split("\n")

ZIELE = ("app.chattr.geraldhofbauer.net {", "chattr.at, www.chattr.at {")


def block_ende(start):
    """Zeilenindex der schliessenden Klammer am Zeilenanfang."""
    for i in range(start + 1, len(zeilen)):
        if zeilen[i].rstrip() == "}":
            return i
    print("FEHLER: kein Blockende ab Zeile %d" % (start + 1))
    sys.exit(1)


geaendert = 0
# Rueckwaerts einsetzen, damit frueher ermittelte Indizes gueltig bleiben.
for ziel in reversed(ZIELE):
    treffer = [i for i, z in enumerate(zeilen) if z.strip() == ziel]
    if not treffer:
        print("  !! %s: Site-Block NICHT gefunden" % ziel[:-2])
        continue
    i = treffer[0]
    if any("X-Frame-Options" in z for z in zeilen[i:block_ende(i)]):
        print("  = %s: hat die Kopfzeilen schon" % ziel[:-2])
        continue
    zeilen[i + 1:i + 1] = BLOCK
    print("  + %s: ergaenzt" % ziel[:-2])
    geaendert += 1

if geaendert:
    open(pfad, "w").write("\n".join(zeilen))

sys.exit(0 if geaendert else 9)   # 9 = nichts zu tun
PY
RC=$?
set -e

if [ "$RC" -eq 9 ]; then
  echo "Nichts zu tun — kein Reload."
  rm -f "$SICHERUNG"
  exit 0
fi
[ "$RC" -eq 0 ] || { echo "Python-Teil fehlgeschlagen (rc=$RC) — Sicherung zurueck."; cp -a "$SICHERUNG" "$CADDYFILE"; exit 1; }

# `caddy validate` PROVISIONS the modules — so it needs the same environment as
# the service. Without it `{env.CF_API_TOKEN}` is empty and Caddy aborts with
# "API token '' appears invalid": a statement about the shell, not about the
# configuration. That is exactly what the first run failed on, on 2026-08-21,
# rolling back a perfectly healthy change.
ENVFILE=/etc/caddy/cloudflare.env
if [ -r "$ENVFILE" ]; then
  set -a; . "$ENVFILE"; set +a
  echo "--- caddy validate (mit $ENVFILE) ---"
  PRUEFUNG="validate"
else
  echo "--- $ENVFILE nicht lesbar -> nur Syntaxpruefung (caddy adapt) ---"
  PRUEFUNG="adapt"
fi

if [ "$PRUEFUNG" = "validate" ]; then
  OK=$(caddy validate --config "$CADDYFILE" --adapter caddyfile 2>&1) || {
    echo "$OK" | tail -3
    echo "UNGUELTIG — Sicherung wird zurueckgespielt."
    cp -a "$SICHERUNG" "$CADDYFILE"; exit 1
  }
else
  # `adapt` checks the syntax without loading modules — the part that says
  # anything at all without the service environment. The rest is caught by the
  # reload: Caddy loads atomically and keeps the OLD configuration on an error.
  caddy adapt --config "$CADDYFILE" --adapter caddyfile >/dev/null || {
    echo "SYNTAX UNGUELTIG — Sicherung wird zurueckgespielt."
    cp -a "$SICHERUNG" "$CADDYFILE"; exit 1
  }
fi
echo "   Konfiguration ok."

# reload, NOT stop: `caddy stop` without --address takes the whole host down
# (2026-08-04, 30+ minutes of outage).
if ! systemctl reload caddy; then
  # Caddy loads atomically: the old state keeps running. Restore the file
  # anyway, so the next restart does not fall back on the broken one.
  echo "RELOAD FEHLGESCHLAGEN — alter Stand laeuft weiter, Datei wird zurueckgesetzt."
  cp -a "$SICHERUNG" "$CADDYFILE"
  systemctl reload caddy || true
  exit 1
fi
echo "--- neu geladen. Nachweis von aussen: ---"
sleep 2
for H in https://chattr.at https://app.chattr.geraldhofbauer.net; do
  echo "== $H"
  curl -sI --max-time 15 "$H" \
    | grep -iE "^(strict-transport|x-frame|x-content-type|referrer-policy|permissions-policy|cross-origin-opener)" \
    | sed 's/^/   /'
done
