# راهنمای ساخت کلاستر ClickHouse از صفر
## ۳ نود · ۱ شارد · ۲ رپلیکا · ClickHouse Keeper · HAProxy

این راهنما فرض می‌کند روی **هر سه ماشین لینوکس** از صفر کلاستر می‌سازی:  
پکیج نصب می‌کنی، کانفیگ را **خودت می‌سازی** (با توضیح هر بخش)، سرویس‌ها را بالا می‌آوری و تست می‌کنی.

| زبان | فایل |
|------|------|
| فارسی | [README.fa.md](README.fa.md) |
| English | [README.md](README.md) |

---

## ۱. معماری هدف

| نود | IP نمونه | چه چیزی بالا می‌آید |
|-----|----------|----------------------|
| Node1 | `192.168.56.129` | `clickhouse-keeper` + `clickhouse-server` (**replica_01**) |
| Node2 | `192.168.56.137` | `clickhouse-keeper` + `clickhouse-server` (**replica_02**) |
| Node3 | `192.168.56.138` | `clickhouse-keeper` + `haproxy` (**بدون** clickhouse-server) |

- نام کلاستر دیتا: `cluster_1S_2R`
- توپولوژی دیتا: **۱ شارد / ۲ رپلیکا** (هر دو نود همان داده را دارند)
- هماهنگی: **ClickHouse Keeper** روی هر ۳ نود (نه Apache ZooKeeper)
- تگ `<zookeeper>` در کانفیگ سرور = کلاینت اتصال به Keeper

```text
Clients --> HAProxy(Node3:19000/18123)
              |              |
              v              v
         Node1 (r1)      Node2 (r2)
              \              /
               Keeper quorum (هر ۳ نود)
```

اگر IP فرق دارد، در تمام کانفیگ‌های پایین همان را عوض کن.

---

## ۱.۱ آدرس‌ها و نحوه اتصال

### آدرس کامل HTTP (مرورگر / Chrome)

| چه چیزی | آدرس کامل در مرورگر |
|---------|---------------------|
| ClickHouse Node1 (HTTP) | http://192.168.56.129:8123/ |
| ClickHouse Node2 (HTTP) | http://192.168.56.137:8123/ |
| ClickHouse از طریق HAProxy (HTTP) | http://192.168.56.138:18123/ |
| کوئری تست Node1 | http://192.168.56.129:8123/?user=default&password=your_password&query=SELECT%201 |
| کوئری تست Node2 | http://192.168.56.137:8123/?user=default&password=your_password&query=SELECT%201 |
| کوئری تست از HAProxy | http://192.168.56.138:18123/?user=default&password=your_password&query=SELECT%201 |
| HAProxy Stats | http://192.168.56.138:8404/stats |

برای Stats یوزر/پسورد مرورگر: `admin` / `admin`

> پورت `8123` و `18123` اینترفیس HTTP هستند و از مرورگر باز می‌شوند.  
> پورت `9000` و `19000` native هستند و برای مرورگر نیستند (`clickhouse-client` / درایور).

### ClickHouse مستقیم (native + HTTP)

| نود | Native | HTTP | نقش |
|-----|--------|------|-----|
| Node1 | `192.168.56.129:9000` | http://192.168.56.129:8123/ | replica_01 |
| Node2 | `192.168.56.137:9000` | http://192.168.56.137:8123/ | replica_02 |

```bash
clickhouse-client --host 192.168.56.129 --port 9000 --user default --password your_password
clickhouse-client --host 192.168.56.137 --port 9000 --user default --password your_password
```

### HAProxy (نقطه ورود پیشنهادی)

| سرویس | آدرس کامل |
|-------|-----------|
| Native | `192.168.56.138:19000` |
| HTTP در مرورگر | http://192.168.56.138:18123/ |
| Stats در مرورگر | http://192.168.56.138:8404/stats |

| سرویس | یوزر | پسورد |
|-------|------|--------|
| ClickHouse | `default` | `your_password` |
| HAProxy Stats | `admin` | `admin` |

```bash
clickhouse-client --host 192.168.56.138 --port 19000 --user default --password your_password
curl "http://default:admin123@192.168.56.138:18123/" --data-binary "SELECT 1"
```

### Keeper (داخلی — در مرورگر باز نمی‌شود)

| نود | Keeper | Raft |
|-----|--------|------|
| Node1 | `192.168.56.129:9181` | `192.168.56.129:9234` |
| Node2 | `192.168.56.137:9181` | `192.168.56.137:9234` |
| Node3 | `192.168.56.138:9181` | `192.168.56.138:9234` |

---

## ۲. پیش‌نیاز هر نود

- Ubuntu/Debian
- دسترسی `sudo`
- زمان همگام (`chrony`/`ntp`)
- شبکه بین نودها باز باشد

رمز آزمایشی این راهنما: `your_password` (در پروداکشن عوض کن).

---

## ۳. نصب پکیج‌ها

### ۳.۱ ریپوی رسمی (روی هر ۳ نود)

```bash
sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/clickhouse.list

sudo apt-get update -y
```

### ۳.۲ پکیج‌ها

**Node1 و Node2:**

```bash
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  clickhouse-server=26.7.3.19 \
  clickhouse-client=26.7.3.19 \
  clickhouse-common-static=26.7.3.19

اگر پسورد `default` پرسید: `your_password`

**Node3:**

```bash
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  clickhouse-keeper=26.7.3.19 \
  haproxy

sudo systemctl disable --now clickhouse-server 2>/dev/null || true
```

سپس روی همه:

```bash
sudo systemctl stop clickhouse-server 2>/dev/null || true
sudo systemctl stop clickhouse-keeper 2>/dev/null || true
```

---

## ۴. ساخت کانفیگ Keeper (هر ۳ نود)

Keeper سرویس جداست. فایل اصلی:

`/etc/clickhouse-keeper/keeper_config.xml`

### چه چیزی داخلش است؟

| بخش | معنی |
|-----|------|
| `tcp_port 9181` | پورتی که Server برای هماهنگی به آن وصل می‌شود |
| `server_id` | هویت این نود در Raft (`1` / `2` / `3`) — روی هر نود فرق دارد |
| `raft_configuration` | لیست هر ۳ عضو quorum |
| `log/snapshot paths` | محل داده داخلی Keeper |

### ساخت پوشه‌ها (هر ۳ نود)

```bash
sudo mkdir -p /etc/clickhouse-keeper
sudo mkdir -p /var/lib/clickhouse-keeper/coordination/{log,snapshots}
sudo mkdir -p /var/log/clickhouse-keeper
```

### فایل Node1 — `server_id = 1`

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

### فایل Node2 — فقط `server_id` را `2` کن

همان فایل؛ این خط فرق دارد:

```xml
<server_id>2</server_id>
```

### فایل Node3 — فقط `server_id` را `3` کن

```xml
<server_id>3</server_id>
```

بعد روی هر نود:

```bash
sudo chown -R clickhouse:clickhouse \
  /etc/clickhouse-keeper \
  /var/lib/clickhouse-keeper \
  /var/log/clickhouse-keeper
```

---

## ۵. ساخت کانفیگ Server (فقط Node1 و Node2)

کانفیگ‌ها را جدا می‌سازیم تا هر بخش یک مسئولیت داشته باشد. مسیر:

`/etc/clickhouse-server/config.d/`

```bash
sudo mkdir -p /etc/clickhouse-server/config.d /etc/clickhouse-server/users.d
sudo rm -f /etc/clickhouse-server/config.d/*.xml
```

### ۵.۱ `01-listen.xml` — گوش دادن شبکه

**چرا؟** سرور روی همه اینترفیس‌ها listen کند و آدرس interserver خودش را بداند.

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

**Node2:** همان، ولی:

```xml
<interserver_http_host>192.168.56.137</interserver_http_host>
```

---

### ۵.۲ `02-macros.xml` — هویت این نود داخل کلاستر

**چرا؟** در `ReplicatedMergeTree` از `{shard}` و `{replica}` استفاده می‌شود. هر نود باید بداند خودش کدام رپلیکاست.

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

(`cluster` و `shard` روی هر دو یکی است چون ۱ شارد داریم.)

---

### ۵.۳ `03-remote_servers.xml` — تعریف شارد و رپلیکاها

**چرا؟** توپولوژی کلاستر را برای `ON CLUSTER` و `Distributed` تعریف می‌کند.

**روی Node1 و Node2 محتوای این فایل یکسان است:**

```bash
sudo tee /etc/clickhouse-server/config.d/03-remote_servers.xml >/dev/null <<'EOF'
<?xml version="1.0"?>
<clickhouse>
    <remote_servers replace="true">
        <cluster_1S_2R>
            <shard>
                <internal_replication>true</internal_replication>

                <!-- رپلیکا ۱ -->
                <replica>
                    <host>192.168.56.129</host>
                    <port>9000</port>
                    <user>default</user>
                    <password>admin123</password>
                </replica>

                <!-- رپلیکا ۲ -->
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

نکته‌ها:
- یک `<shard>` = ۱ شارد
- دو `<replica>` داخل همان شارد = ۲ رپلیکا
- `internal_replication=true` یعنی replication توسط Replicated* انجام شود
- `your_password` برای کوئری بین‌نودی لازم است

---

### ۵.۴ `04-zookeeper.xml` — اتصال Server به Keeper

**چرا؟** سرور باید بداند quorum کیپر کجاست. اسم تگ تاریخی `zookeeper` است؛ اینجا به ClickHouse Keeper وصل می‌شود.

**روی Node1 و Node2 یکسان:**

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

### ۵.۵ `05-distributed_ddl.xml` — مسیر DDL روی کلاستر

**چرا؟** دستورات `ON CLUSTER` از طریق Keeper هماهنگ می‌شوند.

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

### ۵.۶ پسورد یوزر `default`

```bash
sudo tee /etc/clickhouse-server/users.d/default-password.xml >/dev/null <<'EOF'
<?xml version="1.0"?>
<clickhouse>
    <users>
        <default replace="replace">
            <password_sha256_hex>(پسورد هش شده)</password_sha256_hex>
            <networks>
                <ip>192.168.56.0/24</ip>
            </networks>
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

## ۶. ساخت کانفیگ HAProxy (فقط Node3)

**چرا؟** کلاینت‌ها به یک آدرس وصل شوند و بین دو رپلیکا پخش شوند.

پورت‌های `19000` / `18123` عمداً جدا از `9000` / `8123` نودهای دیتا هستند.

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

## ۷. فایروال (نمونه)

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

## ۸. روشن کردن سرویس‌ها (ترتیب مهم)

### ۸.۱ اول Keeper روی هر ۳ نود (Node1 و Node2 و Node3)

روی **Node1** و **Node2** و **Node3** همین را بزن:

```bash
sudo systemctl enable clickhouse-keeper
sudo systemctl restart clickhouse-keeper
sudo systemctl status clickhouse-keeper --no-pager
```

بدون Keeper روی Node3، quorum سه‌تایی کامل نمی‌شود.

### ۸.۲ بعد Server فقط روی Node1 و Node2

```bash
sudo systemctl enable clickhouse-server
sudo systemctl restart clickhouse-server
sudo systemctl status clickhouse-server --no-pager
clickhouse-client --password your_password -q "SELECT version(), hostName()"
```

روی Node3 هیچ‌وقت `clickhouse-server` را استارت نکن.

### ۸.۳ بعد روی Node3: مطمئن شو Keeper بالاست، سپس HAProxy

```bash
# دوباره چک کن که Keeper نود ۳ فعال است
sudo systemctl status clickhouse-keeper --no-pager

# بعد HAProxy
sudo systemctl enable haproxy
sudo systemctl restart haproxy
sudo systemctl status haproxy --no-pager
```

روی Node3 در نهایت باید **هر دو** سرویس بالا باشند:

- `clickhouse-keeper`
- `haproxy`

---

## ۹. ساخت جدول و تست

روی Node1:

```bash
clickhouse-client --password your_password --multiquery <<'SQL'
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

### خروجی مورد انتظار توپولوژی

```text
cluster_1S_2R   1   1   192.168.56.129
cluster_1S_2R   1   2   192.168.56.137
```

### تست HAProxy

```bash
clickhouse-client --host 192.168.56.138 --port 19000 --password your_password -q \
  "SELECT count() FROM demo.events"

curl -s "http://default:admin123@192.168.56.138:18123/" --data-binary "SELECT 1"
```

### تست Keeper

```bash
clickhouse-client --password your_password -q "SELECT name FROM system.zookeeper WHERE path='/'"
```

### نکته UI

جدول `dual` در ClickHouse نیست. از `SELECT 1` استفاده کن.

---

## ۱۰. معنی موتور جداول

| موتور | نقش |
|-------|-----|
| `ReplicatedMergeTree(..., '{replica}')` | داده محلی + همگام‌سازی بین دو رپلیکا از طریق Keeper |
| `Distributed(cluster_1S_2R, ...)` | لایه توزیع‌شده روی کلاستر (اینجا ۱ شارد) |

`{shard}` و `{replica}` از `02-macros.xml` پر می‌شوند.

---

## ۱۱. پورت‌ها

| پورت | کجا | کاربرد |
|------|------|---------|
| 9000 / 8123 | Node1, Node2 | ClickHouse native / HTTP |
| 9009 | Node1, Node2 | interserver |
| 9181 / 9234 | هر ۳ نود | Keeper / Raft |
| 19000 / 18123 | Node3 | ورودی HAProxy |
| 8404 | Node3 | stats |

---

## ۱۲. عیب‌یابی سریع

| مشکل | کار |
|------|-----|
| رپلیکیشن بالا نمی‌آید | هر ۳ Keeper را چک کن؛ `server_id` یکتا باشد |
| `AUTHENTICATION_FAILED` | پسورد دو نود دیتا یکی باشد؛ در `remote_servers` هم نوشته شده باشد |
| Node3 سنگین است | روی آن `clickhouse-server` را خاموش/حذف کن |
| HAProxy به ۹۰۰۰ bind نمی‌شود | از ۱۹۰۰۰ استفاده کن |

لاگ‌ها:

```bash
sudo tail -f /var/log/clickhouse-keeper/clickhouse-keeper.log
sudo tail -f /var/log/clickhouse-server/clickhouse-server.err.log
```

---

## ۱۳. چک‌لیست نهایی

- [ ] ریپو و پکیج روی هر نود درست نصب شده
- [ ] Keeper با `server_id`های ۱/۲/۳ بالا است
- [ ] Node1 = replica_01 ، Node2 = replica_02
- [ ] `remote_servers` یک شارد و دو رپلیکا دارد
- [ ] Node3 فقط Keeper + HAProxy دارد
- [ ] `system.clusters` دو رپلیکا نشان می‌دهد
- [ ] insert/select و مسیر HAProxy کار می‌کند

---

## جمع‌بندی

1. پکیج را با ریپوی رسمی نصب کن.  
2. Keeper را روی هر ۳ نود با `server_id` متفاوت بساز.  
3. روی نودهای دیتا کانفیگ سرور را **تکه‌تکه** بساز: listen، macros، remote_servers، zookeeper-client، ddl، users.  
4. روی Node3 فقط HAProxy بساز.  
5. اول Keeper، بعد Server، بعد HAProxy.  
6. با SQL توپولوژی و رپلیکیشن را تست کن.
