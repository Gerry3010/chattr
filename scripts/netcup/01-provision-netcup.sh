#!/usr/bin/env bash
# 01-provision-netcup.sh — run ON THE FRESH NETCUP VPS as root (or via sudo).
# Installs Docker + compose, nginx, certbot, ufw; creates the `chattr` deploy
# user (same layout as prod so the Bitbucket pipeline only needs SERVER_ADDR +
# a new SSH key), and adds swap so the full Supabase stack is comfortable on 8 GB.
#
# Idempotent-ish: safe to re-run. Does NOT touch DNS, certs, or data.
set -euo pipefail

CHATTR_USER="chattr"
APP_DIR="/home/${CHATTR_USER}/app"
SWAP_GB="${SWAP_GB:-4}"

log() { printf '\n\033[1;32m▶ %s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Bitte als root / mit sudo ausführen."; exit 1; }

log "APT-Pakete (Docker-Repo, nginx, certbot, rsync, ufw)"
apt-get update -y
apt-get install -y ca-certificates curl gnupg rsync ufw nginx \
  certbot python3-certbot-nginx
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "Deploy-User '${CHATTR_USER}' (+ docker-Gruppe) + App-Verzeichnis"
id -u "${CHATTR_USER}" >/dev/null 2>&1 || useradd -m -s /bin/bash "${CHATTR_USER}"
usermod -aG docker "${CHATTR_USER}"
install -d -o "${CHATTR_USER}" -g "${CHATTR_USER}" "${APP_DIR}/supabase" "${APP_DIR}/web" "${APP_DIR}/landing"

log "Swap ${SWAP_GB} GB (falls noch keiner aktiv)"
if ! swapon --show | grep -q .; then
  fallocate -l "${SWAP_GB}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB*1024))
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10 >/dev/null
  grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
else
  echo "Swap bereits aktiv — übersprungen."
fi

log "Firewall (ufw): nur SSH + HTTP/HTTPS"
ufw allow OpenSSH >/dev/null
ufw allow 80/tcp  >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable

log "nginx aktivieren"
systemctl enable --now nginx

cat <<EOF

✅ Provisionierung fertig.
Nächste Schritte (Vorlauf):
  1) SSH-Deploy-Key für 'chattr@<diese-IP>' hinterlegen (~chattr/.ssh/authorized_keys) → für die BB-Pipeline.
  2) nginx-Vhosts aus scripts/netcup/nginx/ nach /etc/nginx/sites-available/ kopieren + verlinken.
  3) TLS-Certs VORAB per DNS-01 ziehen (A-Record zeigt noch auf Prod):
       certbot certonly --manual --preferred-challenges dns \\
         -d api.chattr.geraldhofbauer.net -d app.chattr.geraldhofbauer.net -d chattr.geraldhofbauer.net
     (oder certbot-DNS-Plugin des DNS-Providers, falls vorhanden).
  4) KONG_HTTP_PORT aus der (kopierten) .env in die api-Vhost eintragen, dann 'nginx -t && systemctl reload nginx'.
EOF
