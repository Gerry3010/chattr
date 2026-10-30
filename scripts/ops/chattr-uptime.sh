#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
# Erreichbarkeits-Wache für Chattr-Prod. Läuft auf dem IONOS-Server, also bei
# einem ANDEREN Anbieter als der überwachte Netcup-Host — eine Maschine kann
# ihren eigenen Ausfall nicht melden.
#
# Meldet über pipepush, und zwar nur bei WECHSEL: einmal beim Ausfall, einmal
# bei der Rückkehr. Kein Dauerfeuer, solange etwas unten ist.
#
# Angelegt 2026-09-16, nachdem der Netcup-Server wegen einer offenen Rechnung
# abgeschaltet war und es stundenlang niemandem auffiel.
set -u

SERVER="https://pipepush.geraldhofbauer.net"
TOKEN_FILE="$HOME/.config/chattr-uptime/token"
STATE_FILE="$HOME/.local/state/chattr-uptime.state"

# Stunde für den täglichen Lebenszeichen-Ping (leer = aus). Eine Wache, die
# still stirbt, ist dieselbe Falle wie die, gegen die sie schützt.
HEARTBEAT_HOUR="8"

# Wieviele Fehlschläge in Folge, bevor "unten" gemeldet wird. 2 × 5 Minuten
# schluckt einen einzelnen Aussetzer, ohne die Meldung nennenswert zu verzögern.
FAIL_THRESHOLD=2

mkdir -p "$(dirname "$STATE_FILE")"
[ -r "$TOKEN_FILE" ] || { echo "kein Token in $TOKEN_FILE" >&2; exit 1; }
TOKEN="$(cat "$TOKEN_FILE")"

ts() { date +%s; }

# Ein HTTP-Code oder 000, wenn gar keine Verbindung zustande kam.
#
# FALLE: `curl ... || echo 000` ist falsch. Bei einem Verbindungsfehler druckt
# curl wegen `-w %{http_code}` BEREITS "000" und beendet sich trotzdem mit einem
# Fehlercode — das `||` hängt dann ein zweites an, und in der Meldung stand
# "HTTP 000000". Gefunden beim ersten Probelauf des Alarms, nicht im Ernstfall.
code_of() {
  local c
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$1?pp=$(ts)" 2>/dev/null)
  echo "${c:-000}"
}

# Über die Umgebung überschreibbar, damit der AUSFALL-Pfad geprüft werden kann,
# ohne auf einen echten Ausfall zu warten. Eine Wache, deren Alarm nie gelaufen
# ist, ist keine — das ist dieselbe Lehre wie beim Realtime-Listener.
WEB=$(code_of "${CHATTR_WEB_URL:-https://chattr.at/}")
API=$(code_of "${CHATTR_API_URL:-https://api.chattr.geraldhofbauer.net/auth/v1/health}")

# Die Web-Seite muss 2xx liefern — ein 523 ist genau das Ausfallsignal
# (Cloudflare steht, der Ursprung nicht). Beim Auth-Dienst zählt JEDE
# HTTP-Antwort als lebendig: ohne Schlüssel antwortet er mit 401, und das ist
# korrekt. Nur 000 (keine Verbindung) und 5xx sind ein Ausfall.
web_ok() { [ "$WEB" -ge 200 ] && [ "$WEB" -lt 400 ]; }
api_ok() { [ "$API" != "000" ] && [ "$API" -lt 500 ]; }

if web_ok && api_ok; then NOW=UP; else NOW=DOWN; fi

PREV=UP; FAILS=0; SINCE=$(ts)
[ -r "$STATE_FILE" ] && . "$STATE_FILE"

notify() { # $1=status  $2=text
  curl -sf -X POST "$SERVER/api/webhook" \
    -H "Content-Type: application/json" \
    -d "{\"token\":\"$TOKEN\",\"status\":\"$1\",\"pipeline\":\"uptime\",\"message\":\"$2\"}" \
    >/dev/null 2>&1
}

human() { # Sekunden -> "2h 15m"
  local s=$1
  printf '%dh %dm' $((s/3600)) $(((s%3600)/60))
}

if [ "$NOW" = DOWN ]; then
  FAILS=$((FAILS+1))
  if [ "$PREV" = UP ] && [ "$FAILS" -ge "$FAIL_THRESHOLD" ]; then
    notify failure "Chattr-Prod nicht erreichbar — chattr.at HTTP $WEB, API HTTP $API"
    PREV=DOWN; SINCE=$(ts)
  fi
else
  if [ "$PREV" = DOWN ]; then
    notify success "Chattr-Prod wieder erreichbar — Ausfall dauerte $(human $(( $(ts) - SINCE )))"
    SINCE=$(ts)
  elif [ -n "$HEARTBEAT_HOUR" ] && [ "$(date +%-H)" = "$HEARTBEAT_HOUR" ] \
       && [ "$(date +%-M)" -lt 5 ]; then
    notify success "Wache läuft — chattr.at $WEB, API $API"
  fi
  PREV=UP; FAILS=0
fi

printf 'PREV=%s\nFAILS=%s\nSINCE=%s\n' "$PREV" "$FAILS" "$SINCE" > "$STATE_FILE"
