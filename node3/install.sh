#!/usr/bin/env bash
# Node3 production package:
#   - clickhouse-keeper ONLY (server_id=3)
#   - haproxy (LB in front of replica01/replica02)
#   - NO clickhouse-server
# Usage: sudo bash install.sh
set -euo pipefail

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run with sudo"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gnupg haproxy

curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' -o /tmp/clickhouse-key.asc
gpg --batch --yes --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg /tmp/clickhouse-key.asc
rm -f /tmp/clickhouse-key.asc

ARCH="$(dpkg --print-architecture)"
echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg arch=${ARCH}] https://packages.clickhouse.com/deb stable main" \
  > /etc/apt/sources.list.d/clickhouse.list

apt-get update -y
apt-get install -y clickhouse-keeper

systemctl disable --now clickhouse-server 2>/dev/null || true

mkdir -p /etc/clickhouse-keeper
mkdir -p /var/lib/clickhouse-keeper/coordination/{log,snapshots}
mkdir -p /var/log/clickhouse-keeper
cp -f "$NODE_DIR/keeper/keeper_config.xml" /etc/clickhouse-keeper/keeper_config.xml
chown -R clickhouse:clickhouse /etc/clickhouse-keeper /var/lib/clickhouse-keeper /var/log/clickhouse-keeper

cp -f "$NODE_DIR/haproxy/haproxy.cfg" /etc/haproxy/haproxy.cfg
mkdir -p /var/log/haproxy
touch /var/log/haproxy/haproxy.log

if command -v ufw >/dev/null 2>&1; then
  ufw allow from 192.168.56.0/24 to any port 9181 proto tcp || true
  ufw allow from 192.168.56.0/24 to any port 9234 proto tcp || true
  ufw allow 19000/tcp || true
  ufw allow 18123/tcp || true
  ufw allow from 192.168.56.0/24 to any port 8404 proto tcp || true
fi

systemctl enable clickhouse-keeper
systemctl restart clickhouse-keeper
sleep 2
systemctl --no-pager -l status clickhouse-keeper || true

haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl enable haproxy
systemctl restart haproxy
systemctl --no-pager -l status haproxy || true

echo "Node3 ready: keeper#3 + HAProxy only"
echo "  Native LB : 192.168.56.138:19000"
echo "  HTTP LB   : 192.168.56.138:18123"
echo "  Stats     : http://192.168.56.138:8404/stats"
