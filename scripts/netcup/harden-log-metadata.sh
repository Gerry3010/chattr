#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Log and port hardening for the self-hosted Supabase stack. (Metadata audit
# 2026-08-02, findings A1–A6.)
#
# Background: the access logs say more than the database itself. Kong logs
# request lines INCLUDING the query string (`?chat_id=eq.…&recipient_id=eq.…`),
# GoTrue logs real client IPs beside the user UUID, and Vector writes both
# permanently into Postgres (`_analytics`), where nothing is pruned. That
# reconstructs exactly the social graph deleting the ciphertexts is meant to
# remove — and it even outlives account deletion.
#
# The script is IDEMPOTENT and runs as a DRY RUN by default: it only shows
# diffs. Only `--apply` writes, and even then every file is backed up first. It
# restarts NOTHING by itself — the restart commands are printed at the end so
# you choose the moment.
#
# ./harden-log-metadata.sh # dry run, shows all diffs ./harden-log-metadata.sh
# --apply # writes (with backups) ./harden-log-metadata.sh --apply --prune-logs
# # + a one-off cleanup of _analytics
#
# STAGING FIRST. Then prod.

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

# Shows the diff of a planned change and writes it with --apply.
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

# -------------------------------------------------------------------------- A1
# — switch off the Kong access log (the error log stays) A3/A4 — bind ports to
# 127.0.0.1
#
# CAUTION (chattr-specific): `docker-compose.yml` is rsynced onto the server
# from the repo on EVERY deploy — staging as well as prod. Server-side edits to
# it therefore do NOT survive the next deploy. The hardening is consequently
# already in the repo (`supabase/docker-compose.yml`); on a current server this
# step only reports "already done". For instances not managed by the deploy
# (self-hosting) it still patches normally. Whoever changes the lines in the
# repo has to update the port `sed` patterns in the staging deploy (`bitbucket-
# pipelines.yml`) as well — those match on the exact spelling.
# --------------------------------------------------------------------------
info "A1: Kong-Access-Log nach /dev/null"
tmp="$(mktemp)"
python3 - "$COMPOSE" > "$tmp" <<'PY'
import re, sys
src = open(sys.argv[1]).read()

# 1) Insert KONG_PROXY_ACCESS_LOG under kong.environment (idempotent).
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

# 2) Bind published ports to 127.0.0.1 (only those that are supposed to face
# outwards: Kong HTTP/HTTPS, Logflare, Supavisor/Postgres).
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

# -------------------------------------------------------------------------- A3
# — disconnect the Vector sinks for the metadata-rich sources
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
        # Comment the block out, PRESERVING THE ORIGINAL INDENTATION — otherwise
        # switching it back on is hand work on every line.
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

# -------------------------------------------------------------------------- A6
# — Docker log rotation (a second, independent copy of the same logs)
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
# One-off cleanup of the log archive (opt-in)
# --------------------------------------------------------------------------
if [[ $PRUNE -eq 1 ]]; then
  info "Einmal-Prune des Log-Archivs (_analytics.log_events_*)"

  # Determine the DB container rather than guess: on staging it is called
  # staging-supabase-db.
  DBC="$(docker ps --format '{{.Names}}' | grep -E '(^|-)supabase-db$' | head -1)"
  if [[ -z "$DBC" ]]; then
    warn "Kein supabase-db-Container gefunden — Prune übersprungen."
  else
    echo "    DB-Container: $DBC"
    # The _analytics tables belong to `supabase_admin`, and `postgres` is NOT a
    # superuser in this setup (rolsuper = f) — with -U postgres TRUNCATE fails
    # with "permission denied". A fallback for differing setups.
    PSQL_USER=supabase_admin
    docker exec -i "$DBC" psql -U "$PSQL_USER" -d _supabase -tAc 'SELECT 1' \
      >/dev/null 2>&1 || PSQL_USER=postgres
    echo "    DB-Rolle:     $PSQL_USER"
    # ONLY the log_events_* tables. The schema also contains Logflare's OWN
    # configuration (sources, users, billing_*, endpoint_queries, backends …) —
    # emptying those as well would destroy the ingestion of the sinks that are
    # kept. TRUNCATE (not DELETE) recreates the table files, so the space is
    # free at once; a VACUUM FULL is not needed for it.
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
