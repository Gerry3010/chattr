#!/usr/bin/env bash
# One-time, as root: the directory for coturn and its firewall ports.
#   ssh -t nc-chattr 'sudo bash /tmp/chattr-turn-src/open-firewall.sh'
set -euo pipefail
install -d -o gerry -g gerry -m 0700 /opt/chattr-turn
ufw allow 3478/udp comment 'chattr turn'
ufw allow 3478/tcp comment 'chattr turn'
ufw allow 49160:49359/udp comment 'chattr turn relay'
ufw status | grep -E '3478|49160' 
echo "✓ /opt/chattr-turn + Firewall bereit"
