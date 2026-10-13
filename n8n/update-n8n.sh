#!/usr/bin/env bash
#
# update-n8n.sh - move n8n to the newest release on the n8nio/n8n:stable tag.
#
# The stack runs an exact version (N8N_VERSION in .env), and the task runner image must
# match it. This script finds the version :stable points at. If that is newer, it pulls
# n8n and the matching runner image, backs up the Postgres DB, writes the new version into
# .env and recreates the stack, then waits for it to report healthy.
#
# A new major version (for example 2.x to 3.x) is skipped unless .env sets
# N8N_AUTO_UPDATE_MAJOR=true. Safe to run any time: it is a no-op when there is nothing
# newer. Run it daily from cron (see README).
#
set -euo pipefail

# --- config (edit these) ---------------------------------------------------
RETENTION_DAYS=7          # delete DB backups older than this many days
LOG_MAX_BYTES=5000000     # rotate update-n8n.log to update-n8n.log.1 above this size
WAIT_TIMEOUT=600          # seconds to wait for the stack to become healthy
# ---------------------------------------------------------------------------

# Resolve the stack directory from this script's own location, so the script
# works wherever you put the repo (no hardcoded path).
STACK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$STACK_DIR/backups"
LOG="$STACK_DIR/update-n8n.log"
ENV_FILE="$STACK_DIR/.env"

cd "$STACK_DIR"

# Only one run at a time.
exec 9>"$STACK_DIR/.update-n8n.lock"
flock -n 9 || { echo "another update-n8n.sh run is in progress" >&2; exit 0; }

if [ -f "$LOG" ] && [ "$(stat -c '%s' "$LOG")" -gt "$LOG_MAX_BYTES" ]; then
  mv -f "$LOG" "$LOG.1"
fi
exec >>"$LOG" 2>&1

# Read one value from .env, without sourcing it (it holds secrets and may contain $$).
env_get() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | sed -e 's/^["'\'']//' -e 's/["'\'']$//'
}

TZ="$(env_get GENERIC_TIMEZONE)"
export TZ="${TZ:-Etc/UTC}"
echo "=== $(date '+%F %T %Z') n8n update check ==="

CURRENT="$(env_get N8N_VERSION)"
ALLOW_MAJOR="$(env_get N8N_AUTO_UPDATE_MAJOR)"
if ! [[ "$CURRENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: N8N_VERSION in .env is missing or not an exact version: '$CURRENT'"
  exit 1
fi

# Ask the registry what :stable is now. Downloads layers only if it moved.
docker pull -q n8nio/n8n:stable >/dev/null
TARGET="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' n8nio/n8n:stable)"
if ! [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: could not read a version from n8nio/n8n:stable (got '$TARGET')"
  exit 1
fi

if [ "$TARGET" = "$CURRENT" ]; then
  echo "up to date ($CURRENT) - nothing to do"
  exit 0
fi
if [ "$(printf '%s\n%s\n' "$CURRENT" "$TARGET" | sort -V | tail -n 1)" = "$CURRENT" ]; then
  echo "running $CURRENT, newer than :stable ($TARGET) - nothing to do"
  exit 0
fi
if [ "${CURRENT%%.*}" != "${TARGET%%.*}" ] && [ "$ALLOW_MAJOR" != "true" ]; then
  echo "SKIPPED: :stable is a new major version ($CURRENT -> $TARGET)."
  echo "Read the breaking changes, then set N8N_VERSION=$TARGET by hand or N8N_AUTO_UPDATE_MAJOR=true in .env."
  exit 0
fi

echo "updating $CURRENT -> $TARGET"

# Pull both images before touching anything, so a missing runner image stops the update.
docker pull -q "n8nio/n8n:$TARGET" >/dev/null
docker pull -q "n8nio/runners:$TARGET-distroless" >/dev/null

# n8n database migrations cannot be rolled back, so back up first.
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP="$BACKUP_DIR/n8n-db-$STAMP-v$CURRENT.sql.gz"
# Created owner-only from the start: the dump contains every n8n credential,
# encrypted under N8N_ENCRYPTION_KEY. The default umask would make it 664.
trap 'rm -f "$BACKUP.partial"' EXIT
( umask 077
  docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
    | gzip > "$BACKUP.partial" )
mv "$BACKUP.partial" "$BACKUP"
trap - EXIT
echo "db backup written: $BACKUP ($(stat -c '%a' "$BACKUP"), $(stat -c '%s' "$BACKUP") bytes)"

# Record the new version, then apply it. sed -i keeps the file's owner and mode.
sed -i "s/^N8N_VERSION=.*/N8N_VERSION=$TARGET/" "$ENV_FILE"
if [ "$(env_get N8N_VERSION)" != "$TARGET" ]; then
  echo "ERROR: failed to write N8N_VERSION=$TARGET to .env"
  exit 1
fi

if docker compose up -d --wait --wait-timeout "$WAIT_TIMEOUT"; then
  echo "stack healthy on $TARGET"
else
  echo "ERROR: stack not healthy on $TARGET after ${WAIT_TIMEOUT}s. Check 'docker compose ps' and logs."
  echo "To roll back: restore $BACKUP into Postgres, then set N8N_VERSION=$CURRENT in .env."
  exit 1
fi

# Housekeeping: old DB backups, then n8n images other than the current and previous
# version (images still in use are skipped), then dangling layers.
find "$BACKUP_DIR" -name 'n8n-db-*.sql.gz' -type f -mtime "+$RETENTION_DAYS" -delete
docker image ls --format '{{.Repository}}:{{.Tag}}' \
  | grep -E '^n8nio/(n8n|runners):[0-9]' \
  | grep -vE ":($(printf '%s' "$TARGET" | sed 's/\./\\./g')|$(printf '%s' "$CURRENT" | sed 's/\./\\./g'))(-distroless)?$" \
  | xargs -r docker image rm >/dev/null 2>&1 || true
docker image prune -f

echo "update complete: $CURRENT -> $TARGET"
