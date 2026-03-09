#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log()   { echo -e "${GREEN}[proxysql]${NC} $*"; }
warn()  { echo -e "${YELLOW}[proxysql]${NC} $*"; }
error() { echo -e "${RED}[proxysql]${NC} $*" >&2; }

# -----------------------------------------------------------
# 1. Check prerequisites
# -----------------------------------------------------------
if ! command -v docker &>/dev/null; then
    error "Docker is not installed. Please install Docker first."
    exit 1
fi

if ! command -v envsubst &>/dev/null; then
    error "envsubst is not available. Install gettext:"
    error "  brew install gettext   (macOS)"
    error "  apt install gettext    (Linux)"
    exit 1
fi

# -----------------------------------------------------------
# 2. Load environment variables
# -----------------------------------------------------------
if [[ ! -f .env ]]; then
    error ".env file not found!"
    error "Copy .env.example to .env and fill in your database credentials:"
    error "  cp .env.example .env"
    exit 1
fi

log "Loading environment from .env ..."
set -a
source .env
set +a

# Validate required vars
REQUIRED_VARS=(MYSQL_HOST MYSQL_PORT MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD PROXYSQL_ADMIN_USER PROXYSQL_ADMIN_PASSWORD CACHE_TTL_MS CACHE_SIZE_MB)
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        error "Required variable $var is not set in .env"
        exit 1
    fi
done

# -----------------------------------------------------------
# Determine mode
# -----------------------------------------------------------
# Mode A (remote):   MYSQL_HOST = RDS/external hostname  → only ProxySQL starts
# Mode B (local-dump): MYSQL_HOST = mysql + DUMP_PATH set → local MySQL created from dump
# Mode C (external-local): MYSQL_HOST = host.docker.internal or IP → only ProxySQL starts

COMPOSE_ARGS=()
if [[ "${MYSQL_HOST}" == "mysql" ]]; then
    if [[ -z "${DUMP_PATH:-}" ]]; then
        error "MYSQL_HOST=mysql requires DUMP_PATH to be set in .env"
        exit 1
    fi
    if [[ ! -f "${DUMP_PATH}" ]]; then
        error "Dump file not found: ${DUMP_PATH}"
        exit 1
    fi
    COMPOSE_ARGS=(--profile local)
    log "Mode: local MySQL (dump import from ${DUMP_PATH})"
else
    log "Mode: external MySQL (${MYSQL_HOST}:${MYSQL_PORT})"
fi

# -----------------------------------------------------------
# 3. Generate proxysql.cnf from template
# -----------------------------------------------------------
log "Generating proxysql.cnf from template ..."
envsubst < proxysql.cnf.template > proxysql.cnf
log "Config written to proxysql.cnf"

# -----------------------------------------------------------
# 4. Start docker-compose
# -----------------------------------------------------------
log "Starting ProxySQL container ..."
docker compose "${COMPOSE_ARGS[@]}" up -d

# -----------------------------------------------------------
# 5. Wait for healthy
# -----------------------------------------------------------
MAX_WAIT=60
WAITED=0
log "Waiting for ProxySQL to become healthy (max ${MAX_WAIT}s) ..."

while true; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' proxysql-cache 2>/dev/null || echo "not_found")
    case "$STATUS" in
        healthy)
            break
            ;;
        unhealthy)
            error "Container is unhealthy. Check logs: docker logs proxysql-cache"
            exit 1
            ;;
        not_found)
            if (( WAITED >= MAX_WAIT )); then
                error "Container not found after ${MAX_WAIT}s"
                exit 1
            fi
            ;;
        *)
            if (( WAITED >= MAX_WAIT )); then
                warn "Timed out waiting for healthy status (current: $STATUS)"
                warn "Container may still be starting. Check: docker logs proxysql-cache"
                break
            fi
            ;;
    esac
    sleep 2
    WAITED=$((WAITED + 2))
    printf "."
done
echo ""

# -----------------------------------------------------------
# 6. Print summary
# -----------------------------------------------------------
echo ""
log "${GREEN}ProxySQL is running!${NC}"
echo ""
echo -e "  ${BLUE}MySQL endpoint:${NC}  localhost:6033 → ${MYSQL_HOST}:${MYSQL_PORT}"
echo -e "  ${BLUE}Admin endpoint:${NC}  localhost:6032"
echo -e "  ${BLUE}Database:${NC}        ${MYSQL_DATABASE}"
echo -e "  ${BLUE}Cache TTL:${NC}       $((CACHE_TTL_MS / 1000))s"
echo -e "  ${BLUE}Cache size:${NC}      ${CACHE_SIZE_MB} MB"
echo ""
echo -e "  ${YELLOW}Connect (MySQL):${NC}"
echo -e "    mysql -h 127.0.0.1 -P 6033 -u ${MYSQL_USER} -p"
echo ""
echo -e "  ${YELLOW}Connect (Admin):${NC}"
echo -e "    mysql -h 127.0.0.1 -P 6032 -u ${PROXYSQL_ADMIN_USER} -p${PROXYSQL_ADMIN_PASSWORD}"
echo ""
echo -e "  ${YELLOW}Spring Boot datasource URL:${NC}"
echo -e "    jdbc:mysql://localhost:6033/${MYSQL_DATABASE}?useSSL=false&connectTimeout=5000&socketTimeout=10000"
echo ""
echo -e "  ${YELLOW}View logs:${NC}       docker logs -f proxysql-cache"
echo -e "  ${YELLOW}Stop:${NC}            docker compose down"
echo ""
