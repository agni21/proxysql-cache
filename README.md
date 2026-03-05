# ProxySQL Local Query Cache

Local MySQL query caching proxy using [ProxySQL](https://proxysql.com/). Caches SELECT query results locally so repeated queries are served from memory instead of making round-trips to the remote RDS database.

## Architecture

```
Spring Boot App
      │
      ▼
  localhost:6033  ←── ProxySQL (Docker)
      │                  │
      │            [Query Cache]
      │                  │
      ▼                  ▼
  AWS RDS (us-east-2)
```

## Prerequisites

- **Docker** (with Docker Compose v2)
- **envsubst** — usually pre-installed on Linux; on macOS: `brew install gettext`
- **mysql client** (optional, for testing/admin)

## Quick Start

### 1. Configure credentials

```bash
cd proxysql-cache
cp .env.example .env
# Edit .env with your actual database credentials
```

### 2. Start ProxySQL

```bash
./start.sh
```

This will:
- Validate your `.env`
- Generate `proxysql.cnf` from the template
- Start the Docker container
- Wait until ProxySQL is healthy
- Print connection details

### 3. Connect your Spring Boot app

Update `application-dev.properties`:

```properties
# OLD (direct to remote RDS)
# spring.datasource.url=jdbc:mysql://cuspera-prod-large.crbqd9rjpz5y.us-east-2.rds.amazonaws.com:3306/production?max_allowed_packet=1073741824&useSSL=false&connectTimeout=5000&socketTimeout=10000

# NEW (through local ProxySQL cache)
spring.datasource.url=jdbc:mysql://localhost:6033/production?max_allowed_packet=1073741824&useSSL=false&connectTimeout=5000&socketTimeout=10000
```

No changes to username/password are needed — ProxySQL forwards the same credentials.

### 4. Stop ProxySQL

```bash
./stop.sh
# or
docker compose down
```

---

## Ports

| Port | Purpose |
|------|---------|
| `6033` | MySQL client connections (app connects here) |
| `6032` | ProxySQL admin interface |
| `6070` | REST API / Prometheus metrics |

---

## Monitoring Cache Performance

### Connect to Admin Interface

```bash
mysql -h 127.0.0.1 -P 6032 -u admin -padmin
```

### Check Query Digest (top queries by total time)

```sql
SELECT hostgroup, schemaname, digest_text,
       count_star, sum_time,
       ROUND(sum_time/count_star) AS avg_time_us
FROM stats_mysql_query_digest
ORDER BY sum_time DESC
LIMIT 20;
```

### Check Cache Statistics

```sql
SELECT * FROM stats_mysql_global
WHERE Variable_Name LIKE '%Query_Cache%';
```

Key metrics:
- `Query_Cache_Memory_bytes` — current cache memory usage
- `Query_Cache_count_GET` — total cache lookups
- `Query_Cache_count_GET_OK` — cache hits
- `Query_Cache_count_SET` — queries stored in cache
- `Query_Cache_Purged` — entries evicted
- `Query_Cache_Entries` — current number of cached entries

### Calculate Cache Hit Rate

```sql
SELECT
  (SELECT Variable_Value FROM stats_mysql_global WHERE Variable_Name = 'Query_Cache_count_GET_OK') AS cache_hits,
  (SELECT Variable_Value FROM stats_mysql_global WHERE Variable_Name = 'Query_Cache_count_GET') AS cache_lookups,
  ROUND(
    100.0 * (SELECT Variable_Value FROM stats_mysql_global WHERE Variable_Name = 'Query_Cache_count_GET_OK')
    / NULLIF((SELECT Variable_Value FROM stats_mysql_global WHERE Variable_Name = 'Query_Cache_count_GET'), 0),
    2
  ) AS hit_rate_pct;
```

### Clear Cache

```sql
-- Connect to admin (port 6032)
PROXYSQL FLUSH QUERY CACHE;
```

---

## Query Rules

Query rules are defined in `proxysql.cnf.template` and loaded on startup:

| Rule ID | Pattern | TTL | Purpose |
|---------|---------|-----|---------|
| 1 | `NOW()`, `CURRENT_TIMESTAMP`, `RAND()`, `UUID()`, `SYSDATE()` | 0 (no cache) | Exclude volatile functions |
| 100 | `^SELECT` | 5 minutes | Cache all other SELECTs |

### Modifying Rules at Runtime

You can adjust rules without restarting via the admin interface:

```sql
-- Connect to admin
mysql -h 127.0.0.1 -P 6032 -u admin -padmin

-- Example: change default cache TTL to 10 minutes
UPDATE mysql_query_rules SET cache_ttl = 600000 WHERE rule_id = 100;
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
```

Or apply the complete rule set from `init.sql`:

```bash
mysql -h 127.0.0.1 -P 6032 -u admin -padmin < init.sql
```

---

## Persistence

ProxySQL uses two separate persistence mechanisms:

### Configuration persistence (survives restarts ✅)

All configuration changes made via the admin interface and saved with `SAVE ... TO DISK` are written to `/var/lib/proxysql/proxysql.db` (SQLite) inside the container. This file lives on the Docker named volume `proxysql-cache-data` and survives `docker compose down/up`.

This includes:
- Query rules (`SAVE MYSQL QUERY RULES TO DISK`)
- User settings like `transaction_persistent` (`SAVE MYSQL USERS TO DISK`)
- Global variables like monitor timeouts (`SAVE MYSQL VARIABLES TO DISK`)

### Query result cache (in-memory only ⚠️)

The cached SELECT query responses are stored in RAM only. After a container restart the result cache starts empty and warms up as queries come in. This is expected ProxySQL behavior — the query result cache is not written to disk.

### Reset everything

To wipe both config and cache state:

```bash
docker compose down
docker volume rm proxysql-cache-data
./start.sh
```

---

## Prometheus Metrics

ProxySQL exposes metrics on port `6070` (REST API). You can scrape them with Prometheus:

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'proxysql'
    metrics_path: '/metrics'
    static_configs:
      - targets: ['localhost:6070']
```

---

## Viewing Logs

```bash
# Follow logs
docker logs -f proxysql-cache

# Last 100 lines
docker logs --tail 100 proxysql-cache
```

---

## File Structure

```
proxysql-cache/
├── .env.example          # Template for credentials (committed)
├── .env                  # Actual credentials (gitignored)
├── .gitignore
├── docker-compose.yml    # Docker service definition
├── proxysql.cnf.template # Config template with ${VAR} placeholders
├── proxysql.cnf          # Generated config (gitignored, contains secrets)
├── init.sql              # Additional query rules for admin interface
├── start.sh              # Start script with health check
├── stop.sh               # Stop script
└── README.md
```

---

## Testing Checklist

- [ ] `./start.sh` completes without errors
- [ ] `mysql -h 127.0.0.1 -P 6033 -u <user> -p -e "SELECT 1"`
- [ ] `mysql -h 127.0.0.1 -P 6033 -u <user> -p -e "SELECT * FROM production.category LIMIT 1"`
- [ ] Second identical query is noticeably faster
- [ ] Admin interface: `mysql -h 127.0.0.1 -P 6032 -u admin -padmin`
- [ ] Cache stats show `Query_Cache_count_GET_OK > 0`
- [ ] Spring Boot app starts with `localhost:6033` datasource URL
- [ ] Cache survives `docker compose restart`

---

## Troubleshooting

### Can't connect on port 6033
```bash
# Check container is running
docker ps | grep proxysql

# Check logs for errors
docker logs proxysql-cache
```

### "Access denied" errors
Ensure the username/password in `.env` match exactly what your application uses. ProxySQL must have the same credentials as the backend MySQL server.

### Cache not working (0 hits)
```sql
-- Check rules are loaded
SELECT rule_id, active, match_digest, cache_ttl FROM mysql_query_rules;

-- Ensure rules are in runtime
LOAD MYSQL QUERY RULES TO RUNTIME;
```

### Container unhealthy
```bash
# Check health check details
docker inspect proxysql-cache | jq '.[0].State.Health'
```
