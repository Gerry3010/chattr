#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Private CA + per-device client certificate for the Chattr admin panel (mTLS).
# Run LOCALLY. The panel servers (nginx on IONOS, Caddy on netcup) are configured
# to REQUIRE a client cert signed by this CA — so only devices that import the
# generated .p12 can reach the panel at all.
#
# Flow:
#   1. This script makes a CA (once) and issues a client cert per device.
#   2. Import <device>.p12 into your browser / OS keychain (it will ask for the
#      export password you set here).
#   3. Upload ca.crt to both servers (the setup scripts reference it).
#   4. To enroll another device, run this again and pick a new device name.
#   5. To REVOKE a device: delete its cert from the servers' CA bundle, or roll
#      the CA (re-run with a fresh dir) and re-enroll the devices you keep.
set -euo pipefail

DIR="${CA_DIR:-$HOME/.chattr-admin-ca}"
mkdir -p "$DIR"; cd "$DIR"; umask 077
command -v openssl >/dev/null || { echo "openssl not found"; exit 1; }

# --- CA (created once) -------------------------------------------------------
if [ ! -f ca.crt ]; then
  openssl genrsa -out ca.key 4096
  openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
    -out ca.crt -subj "/CN=Chattr Admin CA/O=Chattr"
  echo "created CA → $DIR/ca.crt"
fi

# --- client cert (per device) ------------------------------------------------
read -rp "device name (e.g. gerry-laptop): " DEV
[ -n "$DEV" ] || { echo "need a device name"; exit 1; }
[ -f "$DEV.p12" ] && { echo "$DEV.p12 already exists — pick another name"; exit 1; }

openssl genrsa -out "$DEV.key" 2048
openssl req -new -key "$DEV.key" -out "$DEV.csr" -subj "/CN=$DEV/O=Chattr Admin"
openssl x509 -req -in "$DEV.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out "$DEV.crt" -days 825 -sha256
rm -f "$DEV.csr"

read -rsp "export password for $DEV.p12 (browser asks for it on import): " P12PW; echo
openssl pkcs12 -export -inkey "$DEV.key" -in "$DEV.crt" -certfile ca.crt \
  -passout pass:"$P12PW" -out "$DEV.p12"
unset P12PW

echo
echo "✓ device bundle → $DIR/$DEV.p12   → import into your browser / keychain"
echo "✓ CA cert       → $DIR/ca.crt     → upload to the servers, e.g.:"
echo "    scp $DIR/ca.crt chattr@<staging-host>:~/chattr-admin-ca.crt     # staging (nginx)"
echo "    scp $DIR/ca.crt chattr@<prod-host>:~/chattr-admin-ca.crt     # prod (Caddy)"
echo
echo "Then run the panel setup scripts (they pick up the CA)."
