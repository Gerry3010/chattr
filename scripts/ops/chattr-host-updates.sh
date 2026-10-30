#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
# Host update watch for the Chattr boxes (nc-chattr = prod, IONOS = staging
# and the uptime watch). Runs as gerry from cron and needs no sudo: `apt
# list`, /var/run/reboot-required, /boot and docker are all readable without
# root. HOST_LABEL names the box in every message (CHAT-24, CHAT-43).
#
# Install (per box, token never on a command line):
#   scp scripts/ops/chattr-host-updates.sh <box>:bin/
#   crontab: 17 9 * * *  HOST_LABEL=<name> $HOME/bin/chattr-host-updates.sh daily
#            23 9 * * 1  HOST_LABEL=<name> $HOME/bin/chattr-host-updates.sh weekly
#
#   daily   reports when apt stopped refreshing its lists, security updates
#           linger, or a reboot has been pending too long. Only on CHANGE,
#           like chattr-uptime.sh: once when it goes bad, once when it heals.
#   weekly  always sends a summary (it doubles as the heartbeat: a watch that
#           dies silently is the same trap it guards against), incl. Docker/
#           Caddy packages and container images whose tag moved upstream.
#
# DRY_RUN=1 prints the message instead of sending it and leaves the state
# file alone, so the alarm path can be exercised without side effects.
set -u

SERVER="https://pipepush.geraldhofbauer.net"
TOKEN_FILE="$HOME/.config/chattr-host-updates/token"
STATE_FILE="$HOME/.local/state/chattr-host-updates.state"
MODE="${1:-daily}"
HOST_LABEL="${HOST_LABEL:-$(hostname -s)}"
DRY_RUN="${DRY_RUN:-0}"

LISTS_MAX_AGE=$((2*86400))   # apt-daily runs twice a day; two days = broken
SEC_MAX_AGE=$((20*3600))     # unattended runs nightly; seen on two mornings = it did not
REBOOT_MAX_AGE=$((48*3600))  # automatic reboot is nightly; 48 h = it did not

now=$(date +%s)
age_of() { [ -e "$1" ] && echo $(( now - $(stat -c %Y "$1") )) || echo -1; }
days() { [ "$1" -lt 0 ] && echo "nie" || echo "$(( $1 / 86400 )) Tg"; }

# --- state -------------------------------------------------------------
BAD=0; SEC_SINCE=0; LAST_TEXT=""
[ -r "$STATE_FILE" ] && . "$STATE_FILE"

# --- checks ------------------------------------------------------------
problems=()

lists_age=$(age_of /var/lib/apt/periodic/update-stamp)
if [ "$lists_age" -lt 0 ] || [ "$lists_age" -gt "$LISTS_MAX_AGE" ]; then
  problems+=("apt-Listen zuletzt aufgefrischt: $(days "$lists_age") (unattended-upgrades aus?)")
fi

mapfile -t sec < <(apt list --upgradable 2>/dev/null | awk -F/ 'NR>1 && /-security/ {print $1}')
if [ "${#sec[@]}" -gt 0 ]; then
  [ "$SEC_SINCE" -eq 0 ] && SEC_SINCE=$now
  if [ $(( now - SEC_SINCE )) -gt "$SEC_MAX_AGE" ]; then
    problems+=("${#sec[@]} Sicherheitsupdates offen seit $(( (now - SEC_SINCE) / 3600 )) h: ${sec[*]:0:8}")
  fi
else
  SEC_SINCE=0
fi

running=$(uname -r)
newest=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V | tail -1)
rr_age=$(age_of /var/run/reboot-required)
kern_age=$(age_of "/boot/vmlinuz-$newest")
if [ "$rr_age" -gt "$REBOOT_MAX_AGE" ]; then
  problems+=("Neustart fällig seit $(( rr_age / 3600 )) h ($(paste -sd' ' /var/run/reboot-required.pkgs 2>/dev/null))")
elif [ -n "$newest" ] && [ "$newest" != "$running" ] && [ "$kern_age" -gt "$REBOOT_MAX_AGE" ]; then
  problems+=("Kernel $running läuft, $newest liegt seit $(( kern_age / 3600 )) h bereit")
fi

notify() { # $1=status  $2=text
  if [ "$DRY_RUN" = 1 ]; then printf '[DRY_RUN] %s: %s\n' "$1" "$2"; return; fi
  [ -r "$TOKEN_FILE" ] || { echo "kein Token in $TOKEN_FILE" >&2; return 1; }
  # JSON via python: the text carries package lists, quotes and newlines.
  python3 -c 'import json,sys; print(json.dumps({"token":sys.argv[1],"status":sys.argv[2],"pipeline":"host-updates","message":sys.argv[3]}))' \
    "$(cat "$TOKEN_FILE")" "$1" "$2" \
  | curl -sf -X POST "$SERVER/api/webhook" -H "Content-Type: application/json" --data-binary @- >/dev/null 2>&1
}

text=$(printf '%s; ' "${problems[@]}"); text=${text%; }

if [ "$MODE" = daily ]; then
  if [ "${#problems[@]}" -gt 0 ]; then
    # Only on change: the first time it goes bad, or when the reason changes.
    if [ "$BAD" = 0 ] || [ "$text" != "$LAST_TEXT" ]; then
      notify failure "$HOST_LABEL Updates: $text"
    fi
    BAD=1; LAST_TEXT=$text
  else
    [ "$BAD" = 1 ] && notify success "$HOST_LABEL Updates wieder im Lot (Kernel $running)"
    BAD=0; LAST_TEXT=""
  fi
else
  # Weekly: packages unattended deliberately leaves alone + image drift.
  manual=$(apt list --upgradable 2>/dev/null | awk -F'[/ ]' 'NR>1 && /^(docker|containerd|caddy)/ {printf "%s %s, ", $1, $3}')
  other=$(apt list --upgradable 2>/dev/null | awk 'NR>1' | grep -vc -- '-security')
  imgs=$(docker ps --format '{{.Image}}' | sort -u | tr '\n' ' ')
  images=$(IMAGES_OF="$imgs" python3 - <<'PY'
import json, os, re, urllib.request

def get(url, headers=None, method="GET"):
    req = urllib.request.Request(url, headers=headers or {}, method=method)
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.headers, r.read()

def split_ref(ref):
    name, tag = ref.rsplit(":", 1) if ":" in ref.split("/")[-1] else (ref, "latest")
    ns, repo = name.split("/", 1) if "/" in name else ("library", name)
    return ns, repo, tag

shape = re.compile(r"^(v?)(\d+(?:\.\d+)*)(.*)$")
def key(t):
    m = shape.match(t)
    return (m.group(1), len(m.group(2).split(".")), m.group(3)) if m else None
def nums(t):
    return tuple(int(x) for x in shape.match(t).group(2).split("."))

# Upstream Supabase compose is the reference for the stack's own images.
upstream = {}
try:
    _, body = get("https://raw.githubusercontent.com/supabase/supabase/master/docker/docker-compose.yml")
    for m in re.finditer(r"^\s*image:\s*(\S+):(\S+)\s*$", body.decode(), re.M):
        upstream[m.group(1)] = m.group(2)
except Exception:
    pass

out = []
for ref in os.environ["IMAGES_OF"].split():
    # A ref pinned by digest (coturn since CHAT-46) is name:tag@sha256:...;
    # split the digest off first, or the colon inside it becomes the "tag".
    ref, _, pinned = ref.partition("@")
    ns, repo, tag = split_ref(ref)
    if "." in ns or ":" not in ref:            # other registry, or a local build / bare id
        continue
    full = repo if ns == "library" else f"{ns}/{repo}"
    notes = []
    # 1) Was the SAME tag rebuilt upstream? Matters for floating tags (4.7, 10.11, 1.27-alpine).
    #    A digest-pinned image cannot drift that way, so it is skipped.
    if not pinned:
        try:
            _, tok = get(f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{ns}/{repo}:pull")
            tok = json.loads(tok)["token"]
            hdr, _ = get(f"https://registry-1.docker.io/v2/{ns}/{repo}/manifests/{tag}", method="HEAD", headers={
                "Authorization": f"Bearer {tok}",
                "Accept": "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json"})
            remote = hdr.get("Docker-Content-Digest", "")
            local = os.popen(f"docker image inspect --format '{{{{json .RepoDigests}}}}' {ref} 2>/dev/null").read()
            if remote and remote not in local:
                notes.append("Tag neu gebaut")
        except Exception:
            pass
    # 2) Newer version: upstream Supabase pin if the repo is part of it, else newest tag of the same shape.
    if full in upstream:
        if upstream[full] != tag:
            notes.append(f"Supabase-Upstream: {upstream[full]}")
    elif key(tag):
        try:
            _, body = get(f"https://hub.docker.com/v2/repositories/{ns}/{repo}/tags?page_size=100&ordering=last_updated")
            tags = [t["name"] for t in json.loads(body)["results"] if key(t["name"]) == key(tag)]
            best = max(tags, key=nums, default=None)
            if best and nums(best) > nums(tag):
                notes.append(f"neuer: {best}" + (" [Major]" if nums(best)[0] != nums(tag)[0] else ""))
        except Exception:
            pass
    if notes:
        out.append(f"{full}:{tag} ({', '.join(notes)})")
print("; ".join(out))
PY
)
  status=success; [ "${#problems[@]}" -gt 0 ] && status=failure
  msg="$HOST_LABEL Wochenbericht — Kernel $running"
  [ -n "$text" ] && msg="$msg | PROBLEME: $text"
  msg="$msg | Sicherheit offen: ${#sec[@]}, sonstige Pakete: $other"
  [ -n "$manual" ] && msg="$msg | von Hand: ${manual%, }"
  # The Caddy on nc-chattr carries the Cloudflare DNS module; the apt build
  # does not, and installing it took prod down on 2026-10-29 (CHAT-24).
  case "$manual" in
    *caddy*) msg="$msg (Caddy: danach sofort caddy add-package github.com/caddy-dns/cloudflare, siehe CLAUDE.md)" ;;
  esac
  [ -n "$images" ] && msg="$msg | Images: $images"
  notify "$status" "$msg"
fi

if [ "$DRY_RUN" != 1 ]; then
  mkdir -p "$(dirname "$STATE_FILE")"
  printf 'BAD=%s\nSEC_SINCE=%s\nLAST_TEXT=%q\n' "$BAD" "$SEC_SINCE" "$LAST_TEXT" > "$STATE_FILE"
fi
