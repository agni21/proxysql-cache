-- ============================================================
-- ProxySQL Query Cache Rules (applied via admin interface)
-- Connect: mysql -h 127.0.0.1 -P 6032 -u admin -padmin
-- ============================================================

-- These rules are already loaded from proxysql.cnf on first start.
-- Use this file to add/modify rules at runtime without restarting.

-- ===================== QUERY RULES ==========================

-- Delete existing rules (optional - use with caution)
-- DELETE FROM mysql_query_rules;

-- Rule: Exclude volatile functions from cache
-- Priority: low rule_id = high priority (checked first)
INSERT INTO mysql_query_rules (rule_id, active, match_digest, cache_ttl, apply)
VALUES (1, 1, '(?i).*(NOW\(\)|CURRENT_TIMESTAMP|RAND\(\)|UUID\(\)|SYSDATE\(\)).*', 0, 1)
ON DUPLICATE KEY UPDATE match_digest='(?i).*(NOW\(\)|CURRENT_TIMESTAMP|RAND\(\)|UUID\(\)|SYSDATE\(\)).*', cache_ttl=0;

-- Rule: Exclude INSERT/UPDATE/DELETE/DROP/ALTER/CREATE from cache (safety)
INSERT INTO mysql_query_rules (rule_id, active, match_digest, cache_ttl, apply)
VALUES (2, 1, '(?i)^(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|TRUNCATE)', 0, 1)
ON DUPLICATE KEY UPDATE cache_ttl=0;

-- Rule: Short TTL (30s) for queries on frequently-changing tables
-- Uncomment and adjust table names as needed:
-- INSERT INTO mysql_query_rules (rule_id, active, match_digest, cache_ttl, apply)
-- VALUES (50, 1, '(?i)^SELECT.*FROM.*(sessions|audit_log|notifications)', 30000, 1);

-- Rule: Long TTL (10 min) for reference/lookup tables
-- Uncomment and adjust table names as needed:
-- INSERT INTO mysql_query_rules (rule_id, active, match_digest, cache_ttl, apply)
-- VALUES (51, 1, '(?i)^SELECT.*FROM.*(category|country|language|config)', 600000, 1);

-- Rule: Cache all remaining SELECT queries (5 min TTL, default)
INSERT INTO mysql_query_rules (rule_id, active, match_digest, cache_ttl, apply)
VALUES (100, 1, '^SELECT', 300000, 1)
ON DUPLICATE KEY UPDATE cache_ttl=300000;

-- ===================== APPLY CHANGES ========================
-- Load rules to runtime and persist to disk
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;

-- ===================== USEFUL QUERIES =======================
-- Check loaded query rules:
-- SELECT rule_id, active, match_digest, cache_ttl, apply FROM mysql_query_rules ORDER BY rule_id;

-- Cache hit statistics:
-- SELECT * FROM stats_mysql_query_digest ORDER BY sum_time DESC LIMIT 20;

-- Global cache stats:
-- SELECT * FROM stats_mysql_global WHERE Variable_Name LIKE '%Query_Cache%';

-- Flush the cache:
-- PROXYSQL FLUSH QUERY CACHE;
