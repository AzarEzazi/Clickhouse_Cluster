# Build a ClickHouse Cluster From Scratch
## 3 nodes · 1 shard · 2 replicas · ClickHouse Keeper · HAProxy

This guide assumes you build the cluster **on all three Linux machines yourself**:  
install packages, **create every config file** (with explanations), start services, and verify.

| Language | File |
|----------|------|
| فارسی | [README.fa.md](README.fa.md) |
| English | [README.md](README.md) |

---

## 1. Target architecture

| Node | Example IP | What runs |
|------|------------|-----------|
| Node1 | `192.168.56.129` | `clickhouse-keeper` + `clickhouse-server` (**replica_01**) |
| Node2 | `192.168.56.137` | `clickhouse-keeper` + `clickhouse-server` (**replica_02**) |
| Node3 | `192.168.56.138` | `clickhouse-keeper` + `haproxy` (**no** clickhouse-server) |

- Data cluster name: `cluster_1S_2R`
- Data topology: **1 shard / 2 replicas** (both nodes hold the same data)
- Coordination: **ClickHouse Keeper** on all 3 nodes (not Apache ZooKeeper)
- The `<zookeeper>` tag in server config is only the **client** block pointing at Keeper

```text
Clients --> HAProxy(Node3:19000/18123)
              |              |
              v              v
         Node1 (r1)      Node2 (r2)
              \              /
               Keeper quorum (all 3 nodes)
```

If your IPs differ, replace them everywhere below.

---

## 1.1 Addresses and how to connect

### Full HTTP URLs (browser / Chrome)

| What | Full browser URL |
|------|------------------|
| ClickHouse Node1 (HTTP) | http://192.168.56.129:8123/ |
| ClickHouse Node2 (HTTP) | http://192.168.56.137:8123/ |
| ClickHouse via HAProxy (HTTP) | http://192.168.56.138:18123/ |
| Test query Node1 | http://192.168.56.129:8123/?user=default&password=admin123&query=SELECT%201 |
| Test query Node2 | http://192.168.56.137:8123/?user=default&password=admin123&query=SELECT%201 |
| Test query via HAProxy | http://192.168.56.138:18123/?user=default&password=admin123&query=SELECT%201 |
| HAProxy Stats | http://192.168.56.138:8404/stats |

Stats login: `admin` / `admin`

> Ports `8123` and `18123` are HTTP and work in a browser.  
> Ports `9000` and `19000` are native protocol (not for Chrome) — use `clickhouse-client` / drivers.

### ClickHouse direct (native + HTTP)

| Node | Native | HTTP | Role |
|------|--------|------|------|
| Node1 | `192.168.56.129:9000` | http://192.168.56.129:8123/ | replica_01 |
| Node2 | `192.168.56.137:9000` | http://192.168.56.137:8123/ | replica_02 |

```bash
clickhouse-client --host 192.168.56.129 --port 9000 --user default --password admin123
clickhouse-client --host 192.168.56.137 --port 9000 --user default --password admin123
```

### HAProxy (recommended entrypoint)

| Service | Full address |
|---------|--------------|
| Native | `192.168.56.138:19000` |
| HTTP in browser | http://192.168.56.138:18123/ |
| Stats in browser | http://192.168.56.138:8404/stats |

| Service | User | Password |
|---------|------|----------|
| ClickHouse | `default` | `admin123` |
| HAProxy Stats | `admin` | `admin` |

```bash
clickhouse-client --host 192.168.56.138 --port 19000 --user default --password admin123
curl "http://default:admin123@192.168.56.138:18123/" --data-binary "SELECT 1"
```

### Keeper (internal — not opened in a browser)

| Node | Keeper | Raft |
|------|--------|------|
| Node1 | `192.168.56.129:9181` | `192.168.56.129:9234` |
| Node2 | `192.168.56.137:9181` | `192.168.56.137:9234` |
| Node3 | `192.168.56.138:9181` | `192.168.56.138:9234` |

---

## 2. Prerequisites (every node)

- Ubuntu/Debian
- `sudo`
- synced time (`chrony`/`ntp`)
- open network between nodes

Lab password used here: `admin123` (change in real production).

---

## 3. Install packages

### 3.1 Official apt repo (all 3 nodes)

```bash
sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/clickhouse.list

sudo apt-get update -y
```

### 3.2 Packages

**Node1 and Node2:**

```bash
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  clickhouse-keeper clickhouse-server clickhouse-client
```

If prompted for `default` password: `admin123`

**Node3:**

```bash
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  clickhouse-keeper haproxy

sudo systemctl disable --now clickhouse-server 2>/dev/null || true
```

Then on all nodes:

```bash
sudo systemctl stop clickhouse-server 2>/dev/null || true
sudo systemctl stop clickhouse-keeper 2>/dev/null || true
```

---

## 4. Create Keeper config (all 3 nodes)

Keeper is a separate service. Main file:

`/etc/clickhouse-keeper/keeper_config.xml`

### What each part means

| Section | Meaning |
|---------|---------|
| `tcp_port 9181` | Port servers use to talk to Keeper |
| `server_id` | This node’s Raft identity (`1` / `2` / `3`) — **different per node** |
| `raft_configuration` | Full 3-member quorum list |
| `log/snapshot paths` | Keeper internal storage |

### Create directories (all 3 nodes)

```bash
sudo mkdir -p /etc/clickhouse-keeper
sudo mkdir -p /var/lib/clickhouse-keeper/coordination/{log,snapshots}
sudo mkdir -p /var/log/clickhouse-keeper
```

### Node1 file — `server_id = 1`

```bash
sudo tee /etc/clickhouse-keeper/keeper_config.xml >/dev/null <<'EOF'
<?xml version="1.0"?>
<clickhouse>
    <logger>
        <level>information</level>
        <log>/var/log/clickhouse-keeper/clickhouse-keeper.log</log>
        <errorlog>/var/log/clickhouse-keeper/clickhouse-keeper.err.log</errorlog>
        <size>1000M</size>
        <count>10</count>
    </logger>
    <listen_host>0.0.0.0</listen_host>
    <keeper_server>
        <tcp_port>9181</tcp_port>
        <server_id>1</server_id>
        <log_storage_path>/var/lib/clickhouse-keeper/coordination/log</log_storage_path>
        <snapshot_storage_path>/var/lib/clickhouse-keeper/coordination/snapshots</snapshot_storage_path>
        <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
            <raft_logs_level>warning</raft_logs_level>
        </coordination_settings>
        <raft_configuration>
            <server><id>1</id><hostname>192.168.56.129</hostname><port>9234</port></server>
            <server><id>2</id><hostname>192.168.56.137</hostname><port>9234</port></server>
            <server><id>3</id><hostname>192.168.56.138</hostname><port>9234</port></server>
        </raft_configuration>
    </keeper_server>
</clickhouse>
EOF
```

### Node2 — same file, only change:

```xml
<server_id>2</server_id>
```

### Node3 — same file, only change:

```xml
<server_id>3</server_id>
```

Then on each node:

```bash
sudo chown -R clickhouse:clickhouse \
  /etc/clickhouse-keeper \
  /var/lib/clickhouse-keeper \
  /var/log/clickhouse-keeper
```

---

## 5. Create Server configs (Node1 and Node2 only)

Split configs so each file has one job. Path:

`/etc/clickhouse-server/config.d/`

```bash
sudo mkdir -p /etc/clickhouse-server/config.d /etc/clickhouse-server/users.d
sudo rm -f /etc/clickhouse-server/config.d/*.xml
```

### 5.1 `01-listen.xml` — network listen

**Why?** Server must listen and advertise its interserver address.

**Node1:**

```bash
sudo tee /etc/clickhouse-server/config.d/01-listen.xml >/dev/null <<'EOF'
<?xml version="1.0"?>
<clickhouse>
    <listen_host>0.0.0.0</listen_host>
    <interserver_http_host>192.168.56.129</interserver_http_host>
    <interserver_http_port>9009</interserver_http_port>
</clickhouse>
EOF
```

**Node2:** same, but:

```xml
<interserver_http_host>192.168.56.137</interserver_http_host>
```

---

### 5.2 `02-macros.xml` — this node’s identity

**Why?** `ReplicatedMergeTree` expands `{shard}` and `{replica}` from macros.

**Node1 (`replica_01`):**

```bash
sudo tee /etc/clickhouse-server/config.d/02-macros.xml >/dev/null <<'EOF'
<?xml version="1.0"?>
<clickhouse>
    <macros>
        <cluster>cluster_1S_2R</cluster>
        <shard>01</shard>
        <replica>replica_01</replica>
    </macros>
</clickhouse>
EOF
```

**Node2 (`replica_02`):**

```xml
<replica>replica_02</replica>
```

(`cluster` and `shard` stay the same — one shard.)

---

### 5.3 `03-remote_servers.xml` — shard + replicas definition

**Why?** Defines topology for `ON CLUSTER` and `Distributed` tables.

**Identical on Node1 and Node2:**

```bash
sudo tee /etc/clickhouse-server/config.d/03-remote_servers.xml >/dev/null <<'EOF'
<?xml version="1.0"?>
<clickhouse>
    <remote_servers replace="true">
        <cluster_1S_2R>
            <shard>
                <internal_replication>true</internal_replication>

                <!-- replica 1 -->
                <replica>
                    <host>192.168.56.129</host>
                    <port>9000</port>
                    <user>default</user>
                    <password>admin123</password>
                </replica>

                <!-- replica 2 -->
                <replica>
                    <host>192.168.56.137</host>
                    <port>9000</port>
                    <user>default</user>
                    <password>admin123</password>
                </replica>
            </shard>
        </cluster_1S_2R>
    </remote_servers>
</clickhouse>
EOF
```

Notes:
- one `<shard>` = 1 shard
- two `<replica>` entries inside it = 2 replicas
- `internal_replication=true` → Replicated* engines own replication
- `user/password` required for inter-node queries

---

### 5.4 `04-zookeeper.xml` — server → Keeper client endpoints

**Why?** Server must know the Keeper quorum. Tag name is historical (`zookeeper`); values point to ClickHouse Keeper.

**Identical on Node1 and Node2:**

```bash
sudo tee /etc/clickhouse-server/config.d/04-zookeeper.xml >/dev/null <<'EOF'
<?xml version="1.0"?>
<clickhouse>
    <zookeeper>
        <node><host>192.168.56.129</host><port>9181</port></node>
        <node><host>192.168.56.137</host><port>9181</port></node>
        <node><host>192.168.56.138</host><port>9181</port></node>
        <session_timeout_ms>30000</session_timeout_ms>
        <operation_timeout_ms>10000</operation_timeout_ms>
    </zookeeper>
</clickhouse>
EOF
```

---

### 5.5 `05-distributed_ddl.xml` — ON CLUSTER DDL path

**Why?** `ON CLUSTER` statements are coordinated through Keeper.

```bash
sudo tee /etc/clickhouse-server/config.d/05-distributed_ddl.xml >/dev/null <<'EOF'
<?xml version="1.0"?>
<clickhouse>
    <distributed_ddl>
        <path>/clickhouse/task_queue/ddl</path>
    </distributed_ddl>
</clickhouse>
EOF
```

---

### 5.6 `default` user password

```bash
sudo tee /etc/clickhouse-server/users.d/default-password.xml >/dev/null <<'EOF'
<?xml version="1.0"?>
<clickhouse>
    <users>
        <default>
            <password>admin123</password>
            <networks><ip>::/0</ip></networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>1</access_management>
        </default>
    </users>
</clickhouse>
EOF

sudo chown -R clickhouse:clickhouse \
  /etc/clickhouse-server/config.d \
  /etc/clickhouse-server/users.d
```

---

## 6. Create HAProxy config (Node3 only)

**Why?** Single client entrypoint across both replicas.

Ports `19000` / `18123` are intentional so they don’t fight data-node `9000` / `8123`.

```bash
sudo tee /etc/haproxy/haproxy.cfg >/dev/null <<'EOF'
global
    log /var/log/haproxy/haproxy.log local0
    maxconn 8192
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5s
    timeout client  300s
    timeout server  300s
    retries 3

frontend ch_native
    bind *:19000
    default_backend ch_native_backends

backend ch_native_backends
    balance roundrobin
    option tcp-check
    server replica01 192.168.56.129:9000 check inter 3s fall 3 rise 2
    server replica02 192.168.56.137:9000 check inter 3s fall 3 rise 2

frontend ch_http
    bind *:18123
    default_backend ch_http_backends

backend ch_http_backends
    balance roundrobin
    option tcp-check
    server replica01 192.168.56.129:8123 check inter 3s fall 3 rise 2
    server replica02 192.168.56.137:8123 check inter 3s fall 3 rise 2

frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats auth admin:admin
EOF

sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```

---

## 7. Firewall (example)

**Node1 / Node2:**

```bash
sudo ufw allow from 192.168.56.0/24 to any port 9000 proto tcp
sudo ufw allow from 192.168.56.0/24 to any port 8123 proto tcp
sudo ufw allow from 192.168.56.0/24 to any port 9009 proto tcp
sudo ufw allow from 192.168.56.0/24 to any port 9181 proto tcp
sudo ufw allow from 192.168.56.0/24 to any port 9234 proto tcp
```

**Node3:**

```bash
sudo ufw allow from 192.168.56.0/24 to any port 9181 proto tcp
sudo ufw allow from 192.168.56.0/24 to any port 9234 proto tcp
sudo ufw allow 19000/tcp
sudo ufw allow 18123/tcp
sudo ufw allow from 192.168.56.0/24 to any port 8404 proto tcp
```

---

## 8. Start services (order matters)

### 8.1 Keeper on all 3 nodes first (Node1, Node2, and Node3)

Run this on **Node1**, **Node2**, and **Node3**:

```bash
sudo systemctl enable clickhouse-keeper
sudo systemctl restart clickhouse-keeper
sudo systemctl status clickhouse-keeper --no-pager
```

Without Keeper on Node3, the 3-node quorum is incomplete.

### 8.2 Then Server on Node1 and Node2 only

```bash
sudo systemctl enable clickhouse-server
sudo systemctl restart clickhouse-server
sudo systemctl status clickhouse-server --no-pager
clickhouse-client --password admin123 -q "SELECT version(), hostName()"
```

Do **not** start `clickhouse-server` on Node3.

### 8.3 Then on Node3: confirm Keeper is up, then start HAProxy

```bash
# confirm Keeper on Node3 is active
sudo systemctl status clickhouse-keeper --no-pager

# then HAProxy
sudo systemctl enable haproxy
sudo systemctl restart haproxy
sudo systemctl status haproxy --no-pager
```

On Node3, **both** services must be running:

- `clickhouse-keeper`
- `haproxy`

---

## 9. Create tables and verify

On Node1:

```bash
clickhouse-client --password admin123 --multiquery <<'SQL'
SELECT cluster, shard_num, replica_num, host_name
FROM system.clusters
WHERE cluster = 'cluster_1S_2R'
ORDER BY shard_num, replica_num;

CREATE DATABASE IF NOT EXISTS demo ON CLUSTER cluster_1S_2R;

CREATE TABLE IF NOT EXISTS demo.events_local ON CLUSTER cluster_1S_2R
(
    event_date Date,
    event_time DateTime,
    user_id UInt64,
    payload String
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/demo/events_local', '{replica}')
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);

CREATE TABLE IF NOT EXISTS demo.events ON CLUSTER cluster_1S_2R
AS demo.events_local
ENGINE = Distributed(cluster_1S_2R, demo, events_local, user_id);

INSERT INTO demo.events
SELECT today(), now(), number, concat('u-', toString(number))
FROM numbers(1000);

SELECT count() FROM demo.events;
SQL
```

### Expected topology

```text
cluster_1S_2R   1   1   192.168.56.129
cluster_1S_2R   1   2   192.168.56.137
```

### HAProxy checks

```bash
clickhouse-client --host 192.168.56.138 --port 19000 --password admin123 -q \
  "SELECT count() FROM demo.events"

curl -s "http://default:admin123@192.168.56.138:18123/" --data-binary "SELECT 1"
```

### Keeper check

```bash
clickhouse-client --password admin123 -q "SELECT name FROM system.zookeeper WHERE path='/'"
```

### UI note

No Oracle `dual` table. Use `SELECT 1`.

---

## 10. What the table engines mean

| Engine | Role |
|--------|------|
| `ReplicatedMergeTree(..., '{replica}')` | Local data + sync between replicas via Keeper |
| `Distributed(cluster_1S_2R, ...)` | Cluster query layer (here: one shard) |

`{shard}` / `{replica}` come from `02-macros.xml`.

---

## 11. Ports

| Port | Where | Purpose |
|------|-------|---------|
| 9000 / 8123 | Node1, Node2 | ClickHouse native / HTTP |
| 9009 | Node1, Node2 | interserver |
| 9181 / 9234 | all 3 | Keeper / Raft |
| 19000 / 18123 | Node3 | HAProxy entry |
| 8404 | Node3 | stats |

---

## 12. Quick troubleshooting

| Issue | Action |
|-------|--------|
| Replication stuck | Check all 3 Keepers; unique `server_id` |
| `AUTHENTICATION_FAILED` | Same password on both data nodes; also in `remote_servers` |
| Node3 heavy | Do not run `clickhouse-server` there |
| HAProxy cannot bind 9000 | Use 19000 |

Logs:

```bash
sudo tail -f /var/log/clickhouse-keeper/clickhouse-keeper.log
sudo tail -f /var/log/clickhouse-server/clickhouse-server.err.log
```

---

## 13. Final checklist

- [ ] Repo + packages installed on each node
- [ ] Keeper up with `server_id` 1/2/3
- [ ] Node1 = replica_01, Node2 = replica_02
- [ ] `remote_servers` has 1 shard and 2 replicas
- [ ] Node3 is Keeper + HAProxy only
- [ ] `system.clusters` shows two replicas
- [ ] insert/select and HAProxy path work

---

## Summary

1. Install packages from the official repo.  
2. Build Keeper on all 3 nodes with different `server_id`.  
3. On data nodes, **create server configs piece by piece**: listen, macros, remote_servers, keeper-client, ddl, users.  
4. On Node3, create HAProxy only (plus Keeper).  
5. Start Keeper → Server → HAProxy.  
6. Verify topology and replication with SQL.
