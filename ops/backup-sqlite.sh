#!/usr/bin/env bash
# ops/backup-sqlite.sh — Consistent SQLite snapshot using .backup (hot, online, safe).
#
# Usage (standalone):
#   DB_PATH=/data/studio.db BACKUP_DIR=/backups ./ops/backup-sqlite.sh
#
# Usage (inside running app container via docker compose exec):
#   docker compose exec app /bin/sh -c 'DB_PATH=/data/studio.db BACKUP_DIR=/data/backups /app/ops/backup-sqlite.sh'
#
# Add to cron (host, example — adjust paths):
#   0 3 * * * /opt/studio/ops/backup-sqlite.sh >> /var/log/studio-backup.log 2>&1
#
# Optional: set S3_BUCKET to ship to S3-compatible storage (requires aws CLI configured):
#   S3_BUCKET=s3://your-bucket/studio/sqlite
set -euo pipefail

DB_PATH="${DB_PATH:-/data/studio.db}"
BACKUP_DIR="${BACKUP_DIR:-/data/backups}"
TS="$(date -u +%Y%m%d-%H%M%S)"
DEST="${BACKUP_DIR}/studio-${TS}.db"

if [ ! -f "${DB_PATH}" ]; then
    echo "ERROR: DB not found at ${DB_PATH}" >&2
    exit 1
fi

mkdir -p "${BACKUP_DIR}"

echo "[backup] Creating snapshot: ${DEST}"
sqlite3 "${DB_PATH}" ".backup '${DEST}'"
echo "[backup] Snapshot complete: $(du -sh "${DEST}" | cut -f1)"

# Optional: ship to S3-compatible storage
if [ -n "${S3_BUCKET:-}" ]; then
    echo "[backup] Uploading to ${S3_BUCKET}/studio-${TS}.db ..."
    aws s3 cp "${DEST}" "${S3_BUCKET}/studio-${TS}.db" --storage-class STANDARD_IA
    echo "[backup] Upload complete."
fi

# Optional: prune local backups older than KEEP_DAYS (default 7)
KEEP_DAYS="${KEEP_DAYS:-7}"
find "${BACKUP_DIR}" -maxdepth 1 -name 'studio-*.db' -mtime +"${KEEP_DAYS}" -delete
echo "[backup] Pruned backups older than ${KEEP_DAYS} days."
