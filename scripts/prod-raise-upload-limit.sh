#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Prod gate stage 6: raise the upload limit to 500 MB
# (api.chattr.geraldhofbauer.net)
#
# Runs ON THE PROD SERVER (<prod-host>). From local:
#   scp scripts/prod-raise-upload-limit.sh <user>@<prod-host>:/tmp/ && \
#   ssh -t <user>@<prod-host> 'sudo bash /tmp/prod-raise-upload-limit.sh'
#
# It does three things:
#  1. nginx vhost api.chattr: client_max_body_size 512m (the default was 1 MiB!)
#     + proxy_request_buffering off (stream large uploads to Kong rather than
#     buffering them to disk).
#  2. FILE_SIZE_LIMIT of supabase-storage to 524288000 (500 MiB) in
#     /home/chattr/app/supabase/docker-compose.yml + a container restart.
#     (Kong has no request-size-limiting plugin — checked 2026-07-11.)
#  3. Test nginx and reload.
set -euo pipefail

VHOST=/etc/nginx/conf.d/chattr.geraldhofbauer.net.conf
COMPOSE_DIR=/home/chattr/app/supabase

echo "→ 1/3 nginx vhost patchen ($VHOST)"
cp "$VHOST" "$VHOST.bak.$(date +%Y%m%d%H%M%S)"
if grep -q "client_max_body_size" "$VHOST"; then
  echo "   client_max_body_size existiert schon — manuell prüfen!"; exit 1
fi
# Insert into the api server block directly after the server_name.
sed -i 's|^  server_name api.chattr.geraldhofbauer.net;$|  server_name api.chattr.geraldhofbauer.net;\n\n  # Storage-Uploads: Client-Limit ist 500 MB (siehe MediaRepository.maxUploadBytes)\n  client_max_body_size 512m;\n  proxy_request_buffering off;|' "$VHOST"
grep -n "client_max_body_size" "$VHOST"

echo "→ 2/3 storage FILE_SIZE_LIMIT (Compose: $COMPOSE_DIR)"
cd "$COMPOSE_DIR"
cp docker-compose.yml "docker-compose.yml.bak.$(date +%Y%m%d%H%M%S)"
# Anchored ([0-9]*$): replaces the WHOLE value idempotently. A bare substring
# pattern once turned an already-correct 524288000 into 5242880000 (extra 0).
sed -i 's/FILE_SIZE_LIMIT: [0-9]*$/FILE_SIZE_LIMIT: 524288000/' docker-compose.yml
grep -n "FILE_SIZE_LIMIT" docker-compose.yml
sudo -u chattr docker compose up -d storage 2>/dev/null || docker compose up -d storage

echo "→ 3/3 nginx test + reload"
nginx -t
systemctl reload nginx

echo "→ Verifikation:"
docker exec supabase-storage sh -c 'env | grep FILE_SIZE'
echo "OK — Limit ist jetzt 500 MB (nginx 512m Headroom)."
