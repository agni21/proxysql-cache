#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "[proxysql] Stopping ProxySQL ..."
docker compose down

echo "[proxysql] Stopped."
echo ""
echo "Note: Cache data is persisted in the Docker volume 'proxysql-cache-data'."
echo "To also remove persisted data:  docker volume rm proxysql-cache-data"
