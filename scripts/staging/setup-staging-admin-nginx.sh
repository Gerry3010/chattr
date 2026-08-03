#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Run ONCE on the IONOS staging box (<staging-host>) as a sudo-capable user.
# Publishes the admin console at https://staging-admin.chattr.geraldhofbauer.net
# behind: HTTP basic_auth + the API's own ADMIN_STATS_SECRET, and OPTIONALLY a
# third gate — mTLS client cert (only enrolled devices). TLS via certbot.
#
# mTLS is a CONFIG TOGGLE (default OFF for easy self-hosting):
#   ADMIN_MTLS=require ./setup-staging-admin-nginx.sh   # require a client cert (Gerry's boxes)
#   ADMIN_MTLS=off     ./setup-staging-admin-nginx.sh   # basic_auth only (default, OSS-friendly)
#
# Prereqs:
#   * DNS staging-admin.chattr.geraldhofbauer.net → <staging-host>  (done via cf)
#   * nginx + certbot installed (they already run the other staging-* vhosts)
#   * the dashboard is served by the admin-proxy sidecar (127.0.0.1:8199)
#   * ONLY when ADMIN_MTLS=require: CA cert at ~/chattr-admin-ca.crt
#     (from scripts/admin-mtls/make-ca-and-cert.sh)
set -euo pipefail

SITE="staging-admin.chattr.geraldhofbauer.net"
ROOT="/home/chattr/staging/admin"
HT="/etc/nginx/.htpasswd-chattr-admin"
CA_SRC="${CA_SRC:-$HOME/chattr-admin-ca.crt}"
CA_DST="/etc/nginx/chattr-admin-ca.crt"
VHOST="/etc/nginx/sites-available/${SITE}.conf"
EMAIL="info@geraldhofbauer.net"
ADMIN_MTLS="${ADMIN_MTLS:-off}"   # require | off (default)

command -v nginx   >/dev/null || { echo "nginx not installed"; exit 1; }
command -v certbot >/dev/null || { echo "certbot not installed"; exit 1; }

# mTLS block is emitted into the vhost only when required.
MTLS_BLOCK=""
if [ "$ADMIN_MTLS" = "require" ]; then
  [ -f "$CA_SRC" ] || { echo "ADMIN_MTLS=require but CA cert not found at $CA_SRC — upload it first (see make-ca-and-cert.sh)"; exit 1; }
  sudo cp "$CA_SRC" "$CA_DST"
  MTLS_BLOCK="
    # --- mTLS: only devices with a client cert signed by our admin CA get in ---
    ssl_client_certificate ${CA_DST};
    ssl_verify_client on;
    ssl_verify_depth 1;
"
  echo "mTLS: REQUIRED (client cert must be signed by ${CA_DST})"
else
  echo "mTLS: OFF (basic_auth only). Set ADMIN_MTLS=require to enforce client certs."
fi

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
${MTLS_BLOCK}
    # --- HTTP basic_auth ---
    auth_basic "Chattr admin (staging)";
    auth_basic_user_file ${HT};

    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;

    # Bound mode: the admin-proxy sidecar in the staging Supabase stack serves
    # the static panel AND injects the ADMIN_STATS_SECRET when proxying
    # /functions/* to Kong. This vhost only terminates TLS + mTLS + basic_auth.
    # (make-staging-compose.sh publishes the sidecar on 127.0.0.1:8199.)
    location / {
        proxy_pass http://127.0.0.1:8199;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX

sudo nginx -t && sudo systemctl reload nginx
echo "✓ https://${SITE} is live — basic_auth${MTLS_BLOCK:+ + client cert (mTLS)}."
echo "  The panel + secret injection are served by the admin-proxy sidecar (bound mode)."
