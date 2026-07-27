#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later

#
# setup-nginx-staging.sh — host-nginx vhosts + TLS for the Chattr staging env.
# Run ON THE VPS AS ROOT (Gerry):  sudo bash scripts/staging/setup-nginx-staging.sh
#
# Creates two server blocks and obtains Let's Encrypt certs via certbot:
#   staging-app.chattr.geraldhofbauer.net  → static web at /home/chattr/staging/web
#   staging-api.chattr.geraldhofbauer.net  → proxy to the staging Kong (127.0.0.1:8100)
#
# Mirrors the prod app/api vhosts. Idempotent-ish: overwrites the two staging
# vhost files, never touches prod configs. DNS A-records for both names must
# already resolve to this host (they do — created via cf).
set -euo pipefail

APP_HOST="staging-app.chattr.geraldhofbauer.net"
API_HOST="staging-api.chattr.geraldhofbauer.net"
WEB_ROOT="/home/chattr/staging/web"
KONG_PORT="8110"                 # matches make-staging-compose.sh (8100 was taken)
SITES="/etc/nginx/sites-available"
ENABLED="/etc/nginx/sites-enabled"
EMAIL="geraldhofbauer9@gmail.com"

[ "$(id -u)" = "0" ] || { echo "must run as root (sudo)"; exit 1; }
command -v nginx >/dev/null || { echo "nginx not installed"; exit 1; }
command -v certbot >/dev/null || { echo "certbot not installed"; exit 1; }

mkdir -p "$WEB_ROOT"
chown -R chattr:chattr /home/chattr/staging 2>/dev/null || true

# --- staging-app: static Flutter web ---------------------------------------
cat > "$SITES/$APP_HOST" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name $APP_HOST;
    root $WEB_ROOT;
    index index.html;
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINX

# --- staging-api: proxy to the staging Kong (Supabase) ---------------------
# proxy_pass to 127.0.0.1:$KONG_PORT; WebSocket upgrade for Realtime.
cat > "$SITES/$API_HOST" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name $API_HOST;
    client_max_body_size 550M;   # media uploads (matches prod ceiling)
    location / {
        proxy_pass http://127.0.0.1:$KONG_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }
}
NGINX

ln -sf "$SITES/$APP_HOST" "$ENABLED/$APP_HOST"
ln -sf "$SITES/$API_HOST" "$ENABLED/$API_HOST"

echo "==> nginx -t"
nginx -t
systemctl reload nginx

echo "==> certbot (HTTP-01) for both hosts"
certbot --nginx --non-interactive --agree-tos -m "$EMAIL" \
    -d "$APP_HOST" -d "$API_HOST" --redirect

nginx -t && systemctl reload nginx
echo "✓ staging vhosts live + TLS: https://$APP_HOST , https://$API_HOST"
