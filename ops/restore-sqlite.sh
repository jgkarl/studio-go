#!/usr/bin/env bash
# ops/restore-sqlite.sh — Restore the Studio SQLite database from a snapshot.
#
# IMPORTANT: Stop the app before restoring to avoid write conflicts.
#
# Usage:
#   SNAPSHOT=/path/to/studio-20260101-030000.db ./ops/restore-sqlite.sh
#
# Or restore from S3 first:
#   aws s3 cp s3://your-bucket/studio/studio-20260101-030000.db /tmp/restore.db
#   SNAPSHOT=/tmp/restore.db ./ops/restore-sqlite.sh
set -euo pipefail

DB_PATH="${DB_PATH:-/data/studio.db}"
SNAPSHOT="${SNAPSHOT:-}"

if [ -z "${SNAPSHOT}" ]; then
    echo "ERROR: Set SNAPSHOT to the backup file path." >&2
    echo "  SNAPSHOT=/path/to/studio-20260101-030000.db $0" >&2
    exit 1
fi

if [ ! -f "${SNAPSHOT}" ]; then
    echo "ERROR: Snapshot file not found: ${SNAPSHOT}" >&2
    exit 1
fi

echo "[restore] Stopping app container (if running via Docker Compose)..."
# Attempt graceful stop; ignore errors if not using compose or already stopped.
docker compose stop app 2>/dev/null || true

# Safety copy of current DB before overwriting.
if [ -f "${DB_PATH}" ]; then
    TS="$(date -u +%Y%m%d-%H%M%S)"
    SAFETY="${DB_PATH}.pre-restore-${TS}"
    echo "[restore] Saving current DB to ${SAFETY}"
    cp "${DB_PATH}" "${SAFETY}"
fi

echo "[restore] Restoring from ${SNAPSHOT} → ${DB_PATH}"
cp "${SNAPSHOT}" "${DB_PATH}"
# Preserve the same permissions as the original DB (app runs as uid=10001 inside the container;
# on the host the volume files are owned by the same uid).
if [ -f "${SAFETY:-}" ]; then
    chmod --reference="${SAFETY}" "${DB_PATH}" 2>/dev/null || true
fi

echo "[restore] Restore complete. Start the app:"
echo "  docker compose start app   # if using Docker Compose"
echo "  sudo systemctl start studio  # if using systemd"
