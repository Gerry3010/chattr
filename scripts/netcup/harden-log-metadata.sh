#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Log- und Port-Härtung für den self-hosted Supabase-Stack.
# (Metadaten-Audit 2026-08-02, Funde A1–A6.)
#
# Hintergrund: die Access-Logs sind aussagekräftiger als die eigentliche
# Datenbank. Kong loggt Request-Zeilen INKLUSIVE Query-String
# (`?chat_id=eq.…&recipient_id=eq.…`), GoTrue loggt echte Client-IPs neben der
# User-UUID, und Vector schreibt beides dauerhaft nach Postgres (`_analytics`),
# wo nichts prunt. Das rekonstruiert genau den Sozialgraph, den das Löschen der
# Chiffrate beseitigen soll — und überlebt sogar die Account-Löschung.
#
# Das Skript ist IDEMPOTENT und läuft standardmäßig als DRY-RUN: es zeigt nur
# Diffs. Erst `--apply` schreibt, und auch dann wird jede Datei vorher gesichert.
# Es startet NICHTS von selbst neu — die Restart-Kommandos werden am Ende
# ausgegeben, damit du den Zeitpunkt wählst.
#
#   ./harden-log-metadata.sh                      # Dry-Run, zeigt alle Diffs
#   ./harden-log-metadata.sh --apply              # schreibt (mit Backups)
#   ./harden-log-metadata.sh --apply --prune-logs # + einmaliges Aufräumen von _analytics
#
# ERST AUF STAGING. Danach Prod.

set -euo pipefail

APPLY=0
PRUNE=0
STACK_DIR=""
CADDYFILE="/etc/caddy/Caddyfile"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)      APPLY=1; shift ;;
    --prune-logs) PRUNE=1; shift ;;
    --dir)        STACK_DIR="$2"; shift 2 ;;
    --caddyfile)  CADDYFILE="$2"; shift 2 ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
done

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[1;33m'; NC=$'\033[0m'
STAMP="$(date +%Y%m%d-%H%M%S)"
CHANGED=()
RESTART_STACK=0
RESTART_CADDY=0
RESTART_DOCKER=0

info() { echo "${GRN}==>${NC} $*"; }
warn() { echo "${YEL}!!${NC} $*"; }
die()  { echo "${RED}FEHLER:${NC} $*" >&2; exit 1; }

# --------------------------------------------------------------------------
# Stack-Verzeichnis finden. Bewusst KEIN Raten: wenn nichts passt, abbrechen.
# --------------------------------------------------------------------------
if [[ -z "$STACK_DIR" ]]; then
  for c in /opt/chattr/supabase /opt/supabase /opt/chattr-supabase \
           "$HOME/supabase" "$HOME/supabase-docker"; do
    if [[ -f "$c/docker-compose.yml" ]]; then STACK_DIR="$c"; break; fi
  done
fi
[[ -n "$STACK_DIR" ]] || die "Stack-Verzeichnis nicht gefunden — bitte --dir <pfad> angeben."
COMPOSE="$STACK_DIR/docker-compose.yml"
VECTOR="$STACK_DIR/volumes/logs/vector.yml"
[[ -f "$COMPOSE" ]] || die "$COMPOSE existiert nicht."

info "Stack:     $STACK_DIR"
info "Caddyfile: $CADDYFILE"
[[ $APPLY -eq 1 ]] || warn "DRY-RUN — es wird nichts geschrieben. Mit --apply anwenden."
echo

backup() {
  local f="$1"
  [[ $APPLY -eq 1 ]] || return 0
  cp -a "$f" "$f.bak-$STAMP"
  echo "    Backup: $f.bak-$STAMP"
}

# Zeigt den Diff einer geplanten Änderung und schreibt sie bei --apply.
apply_file() {
  local target="$1" tmp="$2" label="$3"
  if diff -q "$target" "$tmp" >/dev/null 2>&1; then
    echo "    ${GRN}bereits erledigt${NC} — keine Änderung nötig"
    rm -f "$tmp"; return 1
  fi
  diff -u --color=always "$target" "$tmp" | sed 's/^/    /' || true
  if [[ $APPLY -eq 1 ]]; then
    backup "$target"
    cat "$tmp" > "$target"
    echo "    ${GRN}geschrieben${NC}"
  fi
  rm -f "$tmp"
  CHANGED+=("$label")
  return 0
}

# --------------------------------------------------------------------------
# A1 — Kong-Access-Log abschalten (Error-Log bleibt)
# A3/A4 — Ports auf 127.0.0.1 binden
#
# ACHTUNG (chattr-spezifisch): `docker-compose.yml` wird bei JEDEM Deploy aus dem
# Repo auf den Server rsync't — Staging wie Prod. Serverseitige Edits daran
# überleben den nächsten Deploy also NICHT. Die Härtung steht deshalb bereits im
# Repo (`supabase/docker-compose.yml`); auf einem aktuellen Server meldet dieser
# Schritt nur noch "bereits erledigt". Für nicht deploy-verwaltete Instanzen
# (Self-Hosting) patcht er weiterhin normal.
# Wer die Zeilen im Repo ändert, muss die Port-`sed`-Muster im Staging-Deploy
# (`bitbucket-pipelines.yml`) mitziehen — die matchen auf die exakte Schreibweise.
# --------------------------------------------------------------------------
info "A1: Kong-Access-Log nach /dev/null"
tmp="$(mktemp)"
python3 - "$COMPOSE" > "$tmp" <<'PY'
import re, sys
src = open(sys.argv[1]).read()

# 1) KONG_PROXY_ACCESS_LOG unter kong.environment einfügen (idempotent).
if "KONG_PROXY_ACCESS_LOG" not in src:
    src = src.replace(
        '      KONG_DATABASE: "off"',
        '      # Metadaten-Audit A1: Access-Log AUS. Es enthielt Query-Strings\n'
        '      # (chat_id/recipient_id) und Objektpfade und wurde von Vector\n'
        '      # dauerhaft nach Postgres geschrieben. Fehler-Log bleibt an.\n'
        '      KONG_PROXY_ACCESS_LOG: /dev/null\n'
        '      KONG_DATABASE: "off"',
        1,
    )

# 2) Veröffentlichte Ports an 127.0.0.1 binden (nur die, die nach außen
#    zeigen sollen: Kong HTTP/HTTPS, Logflare, Supavisor/Postgres).
def bind_local(m):
    indent, rest = m.group(1), m.group(2)
    if rest.startswith("127.0.0.1:"):
        return m.group(0)
    return f'{indent}- "127.0.0.1:{rest}"'

for pat in (
    r'( +)- \$\{KONG_HTTP_PORT\}:8000/tcp',
    r'( +)- \$\{KONG_HTTPS_PORT\}:8443/tcp',
    r'( +)- 4000:4000',
    r'( +)- \$\{POSTGRES_PORT\}:5432',
    r'( +)- \$\{POOLER_PROXY_PORT_TRANSACTION\}:6543',
):
    def repl(m, _p=pat):
        line = m.group(0)
        indent = m.group(1)
        value = line.strip()[2:].strip().strip('"')
        if value.startswith("127.0.0.1:"):
            return line
        return f'{indent}- "127.0.0.1:{value}"'
    src = re.sub(pat, repl, src)

sys.stdout.write(src)
PY
apply_file "$COMPOSE" "$tmp" "docker-compose.yml (Kong-Log + Port-Bindings)" && RESTART_STACK=1
echo

# --------------------------------------------------------------------------
# A3 — Vector-Sinks für die metadatenreichen Quellen abklemmen
# --------------------------------------------------------------------------
info "A3: Vector-Sinks kong/auth/realtime/storage deaktivieren"
if [[ ! -f "$VECTOR" ]]; then
  warn "vector.yml nicht gefunden ($VECTOR) — übersprungen."
else
  tmp="$(mktemp)"
  python3 - "$VECTOR" > "$tmp" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
out, i = [], 0
drop = {"logflare_kong", "logflare_auth", "logflare_realtime", "logflare_storage"}
while i < len(lines):
    line = lines[i]
    m = re.match(r'^  (logflare_[a-z_]+):\s*$', line)
    if m and m.group(1) in drop:
        name = m.group(1)
        if out and out[-1].strip().startswith("# Metadaten-Audit A3"):
            out.append(line); i += 1; continue
        out.append(f'  # Metadaten-Audit A3: {name} deaktiviert — diese Quelle')
        out.append('  # persistierte Access-Logs (Query-Strings, Client-IPs, User-UUIDs)')
        out.append('  # unbefristet nach Postgres. Wieder aktivieren nur zum Debuggen.')
        # Block auskommentieren, ORIGINAL-EINRÜCKUNG erhalten — sonst ist das
        # Wieder-Einschalten Handarbeit an jeder Zeile.
        out.append("#" + line)
        i += 1
        while i < len(lines) and (lines[i].startswith("    ") or lines[i].strip() == ""):
            out.append(("#" + lines[i]) if lines[i].strip() else "")
            i += 1
        continue
    out.append(line); i += 1
sys.stdout.write("\n".join(out))
PY
  apply_file "$VECTOR" "$tmp" "vector.yml (Sinks abgeklemmt)" && RESTART_STACK=1
fi
echo

# --------------------------------------------------------------------------
# A2 — X-Forwarded-For am Caddy strippen, damit GoTrue keine echten IPs sieht
# --------------------------------------------------------------------------
info "A2: X-Forwarded-For im api-Block strippen (GoTrue loggt sonst echte IPs)"
if [[ ! -f "$CADDYFILE" ]]; then
  warn "Caddyfile nicht gefunden ($CADDYFILE) — übersprungen."
else
  if grep -q "header_up -X-Forwarded-For" "$CADDYFILE"; then
    echo "    ${GRN}bereits erledigt${NC}"
  else
    warn "Kann nicht sicher automatisch patchen (Caddyfiles sind zu individuell)."
    cat <<'EOF'
    Bitte im api-Block von Hand ergänzen — aus:

        reverse_proxy 127.0.0.1:8000

    wird:

        reverse_proxy 127.0.0.1:8000 {
            header_up -X-Forwarded-For
            header_up -X-Real-IP
        }

    Danach:  sudo caddy validate --config CADDYFILE && sudo systemctl reload caddy
    (Gotcha aus dem Admin-Dashboard-Setup: `caddy validate` scheitert an leerem
     CF_API_TOKEN, weil der nur in der systemd-Env steckt — dann einfach
     `systemctl reload caddy`; bei Fehler bleibt die alte Config aktiv.)
EOF
  fi
fi
echo

# --------------------------------------------------------------------------
# A6 — Docker-Log-Rotation (zweite, unabhängige Kopie derselben Logs)
# --------------------------------------------------------------------------
info "A6: Docker-JSON-Log-Rotation"
DAEMON=/etc/docker/daemon.json
tmp="$(mktemp)"
if [[ -f "$DAEMON" ]]; then
  python3 - "$DAEMON" > "$tmp" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d.setdefault("log-driver", "json-file")
d.setdefault("log-opts", {})
d["log-opts"].setdefault("max-size", "10m")
d["log-opts"].setdefault("max-file", "3")
print(json.dumps(d, indent=2))
PY
  apply_file "$DAEMON" "$tmp" "daemon.json (Log-Rotation)" && RESTART_DOCKER=1
else
  printf '{\n  "log-driver": "json-file",\n  "log-opts": {\n    "max-size": "10m",\n    "max-file": "3"\n  }\n}\n' > "$tmp"
  echo "    $DAEMON existiert nicht — würde angelegt:"
  sed 's/^/      /' "$tmp"
  if [[ $APPLY -eq 1 ]]; then
    mkdir -p /etc/docker && cat "$tmp" > "$DAEMON"
    echo "    ${GRN}angelegt${NC}"
    CHANGED+=("daemon.json (neu)"); RESTART_DOCKER=1
  fi
  rm -f "$tmp"
fi
echo

# --------------------------------------------------------------------------
# A4 — Firewall
# --------------------------------------------------------------------------
info "A4: Firewall-Status"
if command -v ufw >/dev/null 2>&1; then
  ufw status | sed 's/^/    /'
  cat <<'EOF'
    Empfohlen (erst prüfen, dass 22 offen ist — sonst sperrst du dich aus!):
      sudo ufw default deny incoming
      sudo ufw default allow outgoing
      sudo ufw allow 22/tcp && sudo ufw allow 80/tcp && sudo ufw allow 443/tcp
      sudo ufw enable
EOF
else
  warn "ufw nicht installiert — Port-Bindings oben sind dann die einzige Absicherung."
fi
echo

# --------------------------------------------------------------------------
# Einmaliges Aufräumen des Log-Archivs (opt-in)
# --------------------------------------------------------------------------
if [[ $PRUNE -eq 1 ]]; then
  info "Einmal-Prune des Log-Archivs (_analytics.log_events_*)"

  # DB-Container ermitteln statt raten: auf Staging heißt er staging-supabase-db.
  DBC="$(docker ps --format '{{.Names}}' | grep -E '(^|-)supabase-db$' | head -1)"
  if [[ -z "$DBC" ]]; then
    warn "Kein supabase-db-Container gefunden — Prune übersprungen."
  else
    echo "    DB-Container: $DBC"
    # Die _analytics-Tabellen gehören `supabase_admin`, und `postgres` ist in
    # diesem Setup KEIN Superuser (rolsuper = f) — mit -U postgres scheitert
    # TRUNCATE an "permission denied". Fallback für abweichende Setups.
    PSQL_USER=supabase_admin
    docker exec -i "$DBC" psql -U "$PSQL_USER" -d _supabase -tAc 'SELECT 1' \
      >/dev/null 2>&1 || PSQL_USER=postgres
    echo "    DB-Rolle:     $PSQL_USER"
    # NUR die log_events_*-Tabellen. Das Schema enthält auch Logflares EIGENE
    # Konfiguration (sources, users, billing_*, endpoint_queries, backends …) —
    # die mit zu leeren würde die Ingestion der behaltenen Sinks zerstören.
    # TRUNCATE (nicht DELETE) legt die Tabellendateien neu an, der Platz ist
    # also sofort frei; ein VACUUM FULL ist dafür nicht nötig.
    if [[ $APPLY -eq 1 ]]; then
      docker exec -i "$DBC" psql -U "$PSQL_USER" -d _supabase <<'SQL' | sed 's/^/    /'
SELECT pg_size_pretty(pg_database_size('_supabase')) AS vorher;
DO $$
DECLARE t RECORD; n INT := 0;
BEGIN
  FOR t IN
    SELECT tablename FROM pg_tables
    WHERE schemaname = '_analytics' AND tablename LIKE 'log_events%'
  LOOP
    EXECUTE format('TRUNCATE _analytics.%I', t.tablename);
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'geleerte Logtabellen: %', n;
END $$;
SELECT pg_size_pretty(pg_database_size('_supabase')) AS nachher;
SQL
    else
      docker exec -i "$DBC" psql -U "$PSQL_USER" -d _supabase -tAc \
        "SELECT '    (Dry-Run) würde leeren: ' || count(*) || ' Logtabellen, '
              || pg_size_pretty(sum(pg_total_relation_size(format('_analytics.%I', tablename)::regclass)))
         FROM pg_tables WHERE schemaname='_analytics' AND tablename LIKE 'log_events%'" 2>/dev/null
    fi
  fi
  echo
fi

# --------------------------------------------------------------------------
info "Zusammenfassung"
if [[ ${#CHANGED[@]} -eq 0 ]]; then
  echo "    Nichts zu tun — alles bereits gehärtet."
else
  for c in "${CHANGED[@]}"; do echo "    - $c"; done
fi
echo
if [[ $APPLY -eq 1 ]]; then
  echo "  Jetzt noch neu starten:"
  [[ $RESTART_DOCKER -eq 1 ]] && echo "    sudo systemctl restart docker    # startet ALLE Container neu"
  [[ $RESTART_STACK  -eq 1 ]] && echo "    cd $STACK_DIR && docker compose up -d"
  [[ $RESTART_CADDY  -eq 1 ]] && echo "    sudo systemctl reload caddy"
  echo
  echo "  Danach prüfen, dass von AUSSEN nichts mehr offen ist:"
  echo "    curl -sS -m 5 http://<server-ip>:8000/auth/v1/health  # soll fehlschlagen"
  echo "    curl -sS -m 5 http://<server-ip>:4000/health          # soll fehlschlagen"
  echo "    curl -sS https://<api-host>/auth/v1/health            # soll weiter gehen"
else
  echo "  Nichts geschrieben. Mit --apply anwenden."
fi
