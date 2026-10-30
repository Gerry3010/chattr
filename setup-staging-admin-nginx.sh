#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Run ONCE on the IONOS staging box (<staging-host>) as a sudo-capable user.
# Publishes the admin console at https://staging-admin.chattr.geraldhofbauer.net
# with THREE gates: mTLS client cert (only enrolled devices) + HTTP basic_auth +
# (the API's own ADMIN_STATS_SECRET). TLS via certbot; static file_server.
#
# Prereqs:
#   * DNS staging-admin.chattr.geraldhofbauer.net → <staging-host>  (done via cf)
#   * CA cert uploaded to ~/chattr-admin-ca.crt  (from scripts/admin-mtls/make-ca-and-cert.sh)
#   * nginx + certbot installed (they already run the other staging-* vhosts)
#   * the dashboard file is placed by the staging deploy (rsync landing/admin → .../staging/admin)
set -euo pipefail

SITE="staging-admin.chattr.geraldhofbauer.net"
ROOT="/home/chattr/staging/admin"
HT="/etc/nginx/.htpasswd-chattr-admin"
CA_SRC="${CA_SRC:-$HOME/chattr-admin-ca.crt}"
CA_DST="/etc/nginx/chattr-admin-ca.crt"
VHOST="/etc/nginx/sites-available/${SITE}.conf"
EMAIL="info@geraldhofbauer.net"

command -v nginx   >/dev/null || { echo "nginx not installed"; exit 1; }
command -v certbot >/dev/null || { echo "certbot not installed"; exit 1; }
[ -f "$CA_SRC" ] || { echo "CA cert not found at $CA_SRC — upload it first (see make-ca-and-cert.sh)"; exit 1; }

sudo cp "$CA_SRC" "$CA_DST"
sudo mkdir -p "$ROOT"

# basic_auth credentials
read -rp "admin username [admin]: " U; U="${U:-admin}"
if [ -f "$HT" ]; then sudo htpasswd "$HT" "$U"; else sudo htpasswd -c "$HT" "$U"; fi

# 1. Temporary HTTP-only vhost so certbot can validate over :80.
sudo tee "$VHOST" >/dev/null <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${SITE};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 404; }
}
NGINX
sudo ln -sf "$VHOST" /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# 2. Obtain the cert only (we write the vhost ourselves for full mTLS control).
sudo certbot certonly --webroot -w /var/www/html -d "$SITE" \
  --non-interactive --agree-tos -m "$EMAIL"

# 3. Full vhost: HTTPS + mTLS (require a client cert signed by our CA) + basic_auth.
sudo tee "$VHOST" >/dev/null <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${SITE};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${SITE};

    ssl_certificate     /etc/letsencrypt/live/${SITE}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${SITE}/privkey.pem;

    # --- mTLS: only devices with a client cert signed by our admin CA get in ---
    ssl_client_certificate ${CA_DST};
    ssl_verify_client on;
    ssl_verify_depth 1;

    root ${ROOT};
    index index.html;

    # --- second factor: HTTP basic_auth ---
    auth_basic "Chattr admin (staging)";
    auth_basic_user_file ${HT};

    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;

    location / { try_files \$uri \$uri/ /index.html; }
}
NGINX

sudo nginx -t && sudo systemctl reload nginx
echo "✓ https://${SITE} is live — requires a client cert + basic_auth."
echo "  Dashboard connect gate → API base: https://staging-api.chattr.geraldhofbauer.net"
