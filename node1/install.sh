#!/usr/bin/env bash
# Node1 production package:
#   - clickhouse-keeper (standalone)
#   - clickhouse-server (data: shard01 / replica_01)
# Usage: sudo bash install.sh
set -euo pipefail

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CH_PASSWORD="admin123"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run with sudo"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gnupg

curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' -o /tmp/clickhouse-key.asc
gpg --batch --yes --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg /tmp/clickhouse-key.asc
rm -f /tmp/clickhouse-key.asc

ARCH="$(dpkg --print-architecture)"
echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg arch=${ARCH}] https://packages.clickhouse.com/deb stable main" \
  > /etc/apt/sources.list.d/clickhouse.list

apt-get update -y
echo "clickhouse-server clickhouse-server/default-password password ${CH_PASSWORD}" | debconf-set-selections
echo "clickhouse-server clickhouse-server/default-password seen true" | debconf-set-selections

apt-get install -y clickhouse-keeper clickhouse-server clickhouse-client

systemctl stop clickhouse-server || true
systemctl stop clickhouse-keeper || true

# --- Keeper (standalone) ---
mkdir -p /etc/clickhouse-keeper
mkdir -p /var/lib/clickhouse-keeper/coordination/{log,snapshots}
mkdir -p /var/log/clickhouse-keeper
cp -f "$NODE_DIR/keeper/keeper_config.xml" /etc/clickhouse-keeper/keeper_config.xml
chown -R clickhouse:clickhouse /etc/clickhouse-keeper /var/lib/clickhouse-keeper /var/log/clickhouse-keeper

# --- Server split configs ---
rm -f /etc/clickhouse-server/config.d/*.xml
mkdir -p /etc/clickhouse-server/config.d /etc/clickhouse-server/users.d
cp -f "$NODE_DIR/config.d/"*.xml /etc/clickhouse-server/config.d/
cp -f "$NODE_DIR/users.d/"*.xml  /etc/clickhouse-server/users.d/
chown -R clickhouse:clickhouse /etc/clickhouse-server/config.d /etc/clickhouse-server/users.d

if command -v ufw >/dev/null 2>&1; then
  ufw allow from 192.168.56.0/24 to any port 9000 proto tcp || true
  ufw allow from 192.168.56.0/24 to any port 8123 proto tcp || true
  ufw allow from 192.168.56.0/24 to any port 9009 proto tcp || true
  ufw allow from 192.168.56.0/24 to any port 9181 proto tcp || true
  ufw allow from 192.168.56.0/24 to any port 9234 proto tcp || true
fi

# Start Keeper first, then Server
systemctl enable clickhouse-keeper clickhouse-server
systemctl restart clickhouse-keeper
sleep 2
systemctl restart clickhouse-server
sleep 3
systemctl --no-pager -l status clickhouse-keeper || true
systemctl --no-pager -l status clickhouse-server || true
echo "Node1 ready: keeper#1 + server replica_01"
