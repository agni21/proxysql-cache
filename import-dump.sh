#!/bin/bash
# MySQL docker-entrypoint-initdb.d script
# Imports the production dump into the local MySQL container.
set -e

echo "[import-dump] Importing production dump — this may take several minutes..."
zcat /tmp/dump/production.gz | mysql -u root -p"${MYSQL_ROOT_PASSWORD}" "${MYSQL_DATABASE}"
echo "[import-dump] Import complete."
