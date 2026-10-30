#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Sets a Content Security Policy for the web app — AT FIRST AS A REPORT ONLY
# (`Content-Security-Policy-Report-Only`).
#
# WHY NOT ARMED STRAIGHT AWAY: Flutter Web loads its Skia/WASM via
# 'wasm-unsafe-eval', starts workers from blob URLs, registers a service worker and
# talks to Supabase over a websocket. If a single source is missing, the browser
# blocks it — and Flutter then shows not an error but a WHITE SCREEN. Report-Only
# reports the same violations in the console but blocks nothing: we see what the
# real app actually touches before anybody loses anything.
#
# PROCEDURE: 1) this script  2) open the app in Chrome and REALLY USE IT (sign in,
# open a chat with a profile picture, a YouTube link, a Reddit video, send media)
# 3) collect the violations from the console  4) update the policy  5) only then
# remove `-Report-Only` from the header name.
#
# ⚠️ ON 2026-08-21 IT WAS EXACTLY STEP 2 THAT WENT WRONG — and the fault was not
# the policy but the measurement. The report run showed zero violations, from which
# "the policy fits" was concluded. But Report-Only BLOCKS nothing: what went through
# went through, whether or not the policy would have allowed it. Zero violations
# therefore only means "the click-through that was tested touched nothing", never
# "the policy is complete". Once armed, ALL TEXT was missing in the app — Flutter
# Web fetches its fonts at runtime from fonts.gstatic.com, only www.gstatic.com was
# allowed (a different host), and CanvasKit simply draws nothing without a font.
#
# Two things from that which save time next time:
#   * The BLOCKED request does NOT appear in the network list — it is discarded
#     before it goes out. Only the console shows it.
#   * What the page CAN touch at all is revealed by the shipped bundle:
#     `curl .../main.dart.js | grep -oE 'https://[a-z0-9._-]+\.[a-z]{2,}'`.
#     That is exactly how the three gaps below came to light.
#
# ⚠️ AND AGAIN ON 2026-08-23, at the same spot for a different reason: once armed,
# the app showed NOT A SINGLE preview image any more — no YouTube, no og images
# from foreign pages — and the YouTube player threw a bare `Uncaught Error`. What
# was allowed was `img-src … https:`, so seemingly everything. Except: FLUTTER WEB
# DOES NOT LOAD IMAGES AS <img>. CanvasKit fetches them, and fetch falls under
# `connect-src`. With this app `img-src` is nearly decorative; the image hosts
# belong in connect-src. Whoever does not know that reads a generous line and looks
# for the fault everywhere else.
# The second part of the same evening: the YouTube frame is a `srcdoc` frame, so it
# has no origin of its own and inherits OUR policy — its `iframe_api` therefore
# needs www.youtube.com in `script-src`, not merely in `frame-src`.
#
# Run ON THE SERVER (nc-chattr):  sudo bash ~/add-csp-report-only.sh
set -euo pipefail

CADDYFILE=/etc/caddy/Caddyfile
STAMP=$(date +%Y%m%d-%H%M%S)
SICHERUNG="$CADDYFILE.bak-csp-$STAMP"

[ -f "$CADDYFILE" ] || { echo "FEHLER: $CADDYFILE fehlt — laeuft das hier auf nc-chattr?"; exit 1; }
cp -a "$CADDYFILE" "$SICHERUNG"
echo "Sicherung: $SICHERUNG"

echo "--- Site-Block ---"
set +e
python3 - "$CADDYFILE" <<'PY'
import sys

pfad = sys.argv[1]
zeilen = open(pfad).read().split("\n")

# One line, because Caddy would otherwise read the value as several arguments.
CSP = " ".join([
    "default-src 'self';",
    # 'wasm-unsafe-eval' is needed for Flutter's CanvasKit/Skwasm; 'unsafe-
    # inline' covers the bootstrap snippet in index.html. Both get checked again
    # after the report — whatever is not needed goes. www.youtube.com stands
    # here because youtube_player_iframe builds its frame as `srcdoc` — a srcdoc
    # frame has NO origin of its own, it inherits our policy. The `iframe_api`
    # script inside it is therefore checked against THIS line, not against
    # YouTube's own. Without the host the API never loads, and the player
    # afterwards throws a bare `Uncaught Error`.
    "script-src 'self' 'wasm-unsafe-eval' 'unsafe-inline' https://www.gstatic.com"
    " https://www.youtube.com https://*.ytimg.com;",
    "style-src 'self' 'unsafe-inline';",
    # ⚠️ THIS LINE DOES ALMOST NOTHING — and on 2026-08-23 that was the whole
    # fault. Flutter Web draws with CanvasKit and fetches every image via
    # fetch/XHR, not as <img>. So `connect-src` applies, NOT `img-src`. `img-src
    # … https:` looked generous and still killed every link preview, because
    # connect-src was narrow. Whoever allows something here has to allow it
    # AGAIN below, otherwise nothing happens.
    "img-src 'self' data: blob: https:;",
    # v.redd.it: Reddit videos run as an HLS playlist from there
    # (message_links.dart:90) — playback is media-src, fetching the segments is
    # connect-src. Both are needed, one alone does not do it.
    "media-src 'self' blob: https://api.chattr.geraldhofbauer.net"
    " https://v.redd.it;",
    # fonts.gstatic.com is NOT www.gstatic.com. Flutter Web fetches its fonts
    # from there at runtime; without the host CanvasKit draws no text at all —
    # the app then looks empty rather than broken.
    "font-src 'self' data: https://fonts.gstatic.com;",
    # REST and realtime on the same host — wss: has to stand there in its own
    # right, https does NOT cover it. Plus the Firebase endpoints for web push.
    #
    # The preview's TEXT still comes over our own host — the page fetches an
    # edge function, the browser does not (CORS). But the browser fetches the
    # IMAGE, and it does so via fetch (see img-src above) — which is why the
    # image hosts have to stand HERE: *.ytimg.com — YouTube thumbnails (i1..i4,
    # s.ytimg.com) *.youtube.com — img.youtube.com/vi/…/hqdefault.jpg, plus the
    # iframe API's own requests *.redd.it — preview/i/external-preview for
    # Reddit previews
    #
    # DELIBERATELY NO `https:`: the page would then be allowed to send decrypted
    # content to any host in the world, and connect-src would be finished as a
    # protection. A foreign page with an og image that is not listed here
    # therefore shows no preview image on web — the price of a narrow list. The
    # clean way out would be an image proxy of our own at the API host; until
    # then: enumerate.
    "connect-src 'self' https://api.chattr.geraldhofbauer.net"
    " wss://api.chattr.geraldhofbauer.net https://*.googleapis.com"
    " https://www.gstatic.com https://fonts.gstatic.com https://v.redd.it"
    " https://*.redd.it https://*.youtube.com https://*.ytimg.com;",
    # youtube_player_iframe renders a real <iframe> on web. Without frame-src it
    # falls back to default-src 'self' and the player stays black. The package
    # uses the -nocookie variant by default; both stand here because it switches
    # depending on the call.
    "frame-src https://www.youtube.com https://www.youtube-nocookie.com;",
    # sqflite-ffi-web and the service worker start from blob URLs.
    "worker-src 'self' blob:;",
    "frame-ancestors 'none';",
    "base-uri 'self';",
    "form-action 'self';",
    "object-src 'none'",
])

ZIEL = "app.chattr.geraldhofbauer.net {"

treffer = [i for i, z in enumerate(zeilen) if z.strip() == ZIEL]
if not treffer:
    print("  !! Site-Block NICHT gefunden")
    sys.exit(1)
i = treffer[0]

ende = None
for j in range(i + 1, len(zeilen)):
    if zeilen[j].rstrip() == "}":
        ende = j
        break
if ende is None:
    print("  !! kein Blockende gefunden")
    sys.exit(1)

# An existing CSP line is REPLACED, not skipped: the policy is updated after
# every report, and a script that then reports "already there" silently delivers
# the old state.
alt = [j for j in range(i, ende) if "Content-Security-Policy" in zeilen[j]]
if alt:
    # KEEP THE MODE the server is currently running. This branch used to write
    # `-Report-Only` back every time — whoever updated an armed policy thereby
    # disarmed it silently and never noticed, because the page went on working.
    # Switching over happens with csp-enforce.sh, nowhere else.
    scharf = "Content-Security-Policy-Report-Only" not in zeilen[alt[0]]
    kopf = "Content-Security-Policy" if scharf else "Content-Security-Policy-Report-Only"
    print("  (Modus bleibt: %s)" % ("SCHARF" if scharf else "BERICHT"))
    neu_zeile = "\theader %s \"%s\"" % (kopf, CSP)
    if zeilen[alt[0]] == neu_zeile:
        print("  = CSP ist bereits auf diesem Stand")
        sys.exit(9)
    zeilen[alt[0]] = neu_zeile
    print("  ~ CSP aktualisiert")
    open(pfad, "w").write("\n".join(zeilen))
    sys.exit(0)

zeilen[i + 1:i + 1] = [
    "\t# CSP — vorerst NUR BERICHT. Scharfschalten erst, wenn die Konsole beim",
    "\t# echten Durchklicken keine Verstoesse mehr meldet: Eine fehlende Quelle",
    "\t# ergibt bei Flutter einen weissen Bildschirm, keine Fehlermeldung.",
    "\theader Content-Security-Policy-Report-Only \"%s\"" % CSP,
]
print("  + CSP (Report-Only) ergaenzt")
open(pfad, "w").write("\n".join(zeilen))
sys.exit(0)
PY
RC=$?
set -e

if [ "$RC" -eq 9 ]; then
  echo "Nichts zu tun — kein Reload."; rm -f "$SICHERUNG"; exit 0
fi
[ "$RC" -eq 0 ] || { echo "Fehlgeschlagen (rc=$RC) — Sicherung zurueck."; cp -a "$SICHERUNG" "$CADDYFILE"; exit 1; }

# The same environment as the service, otherwise `validate` measures the shell
# instead of the configuration (see add-security-headers.sh).
ENVFILE=/etc/caddy/cloudflare.env
[ -r "$ENVFILE" ] && { set -a; . "$ENVFILE"; set +a; }

echo "--- caddy validate ---"
if ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
  caddy validate --config "$CADDYFILE" --adapter caddyfile 2>&1 | tail -3
  echo "UNGUELTIG — Sicherung wird zurueckgespielt."
  cp -a "$SICHERUNG" "$CADDYFILE"; exit 1
fi
echo "   Konfiguration ok."

if ! systemctl reload caddy; then
  echo "RELOAD FEHLGESCHLAGEN — alter Stand laeuft weiter, Datei wird zurueckgesetzt."
  cp -a "$SICHERUNG" "$CADDYFILE"; systemctl reload caddy || true; exit 1
fi

echo "--- neu geladen. Nachweis von aussen: ---"
sleep 2
curl -sI --max-time 15 https://app.chattr.geraldhofbauer.net \
  | grep -i "content-security-policy" | fold -w 100 | sed 's/^/   /'
