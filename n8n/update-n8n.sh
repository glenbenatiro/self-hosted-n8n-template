#!/usr/bin/env bash
#
# update-n8n.sh - check whether the n8n :stable tag has moved; if so,
# back up the Postgres DB, pull the new image, and recreate the n8n stack.
#
# Only touches the n8n containers (web + workers). Postgres and Redis are
# pinned and left alone. Safe to run any time: it is a no-op when :stable
# has not moved. Run it daily from cron (see README).
#
set -euo pipefail

# --- config (edit these) ---------------------------------------------------
IMAGE="n8nio/n8n:stable"
WORKERS=2                 # how many n8n-worker replicas to keep running
RETENTION_DAYS=7          # delete DB backups older than this many days
TIMEZONE="Etc/UTC"        # set to your GENERIC_TIMEZONE (e.g. America/New_York)
                          # so log and backup timestamps read in local time
# ---------------------------------------------------------------------------

# Resolve the stack directory from this script's own location, so the script
# works wherever you put the repo (no hardcoded path).
STACK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$STACK_DIR/backups"
LOG="$STACK_DIR/update-n8n.log"
export TZ="$TIMEZONE"

cd "$STACK_DIR"
exec >>"$LOG" 2>&1
echo "=== $(date '+%F %T %Z') n8n update check ==="

# Current local image id for the tag (may not exist yet -> "none")
OLD=$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || echo none)

# Ask the registry for the current :stable - downloads layers only if it moved
docker compose pull n8n-web n8n-worker

NEW=$(docker image inspect --format '{{.Id}}' "$IMAGE")

if [ "$OLD" = "$NEW" ]; then
  echo "up to date ($NEW) - nothing to do"
  exit 0
fi

echo "stable moved: $OLD -> $NEW ; backing up DB then updating"
mkdir -p "$BACKUP_DIR"
STAMP=$(date '+%Y%m%d-%H%M%S')
# Dump using the container's own POSTGRES_USER/POSTGRES_DB env vars
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  | gzip > "$BACKUP_DIR/n8n-db-$STAMP.sql.gz"
echo "db backup written: $BACKUP_DIR/n8n-db-$STAMP.sql.gz"

# Recreate n8n on the new image, preserving the worker count
docker compose up -d --scale "n8n-worker=$WORKERS"

# Housekeeping: prune old DB backups and dangling images
find "$BACKUP_DIR" -name 'n8n-db-*.sql.gz' -type f -mtime "+$RETENTION_DAYS" -delete
docker image prune -f

echo "update complete -> $NEW"
