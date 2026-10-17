#!/usr/bin/env bash
#
# update-n8n.sh - move n8n to the newest release on its update channel (stable or beta).
#
# The stack runs an exact version (N8N_VERSION in .env). This script finds the version the
# channel tag (n8nio/n8n:stable or n8nio/n8n:beta) points at. If that is newer, it pulls n8n
# (and the matching task runner image, if the stack uses one), backs up the Postgres DB,
# writes the new version into .env and recreates the stack, then waits for it to come up.
#
# Settings live in .env, so the script itself is the same on every server:
#   N8N_UPDATE_CHANNEL       stable (default) or beta
#   N8N_AUTO_UPDATE_MAJOR    true to also move to a new major version (default: skip them)
#   N8N_UPDATE_KEEP_BACKUPS  how many DB backups to keep, newest first (default 7)
#
# Safe to run any time: it is a no-op when there is nothing newer, and it never moves to an
# older version. Run it daily from cron (see README). `update-n8n.sh --check` prints what it
# would do and changes nothing.
#
set -euo pipefail

# --- config (edit these) ---------------------------------------------------
LOG_MAX_BYTES=5000000     # rotate update-n8n.log to update-n8n.log.1 above this size
WAIT_TIMEOUT=600          # seconds to wait for the stack to become healthy
APT_WAIT_MAX=3600         # seconds to wait for a running OS package upgrade to finish
# ---------------------------------------------------------------------------

CHECK_ONLY=false
case "${1:-}" in
  "") ;;
  --check) CHECK_ONLY=true ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

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

# A check prints to the terminal; a real run appends to the log.
if [ "$CHECK_ONLY" = false ]; then
  if [ -f "$LOG" ] && [ "$(stat -c '%s' "$LOG")" -gt "$LOG_MAX_BYTES" ]; then
    mv -f "$LOG" "$LOG.1"
  fi
  exec >>"$LOG" 2>&1
fi

# Read one value from .env, without sourcing it (it holds secrets and may contain $$).
env_get() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | sed -e 's/^["'\'']//' -e 's/["'\'']$//'
}

TZ="$(env_get GENERIC_TIMEZONE)"
export TZ="${TZ:-Etc/UTC}"
echo "=== $(date '+%F %T %Z') n8n update check ==="

CURRENT="$(env_get N8N_VERSION)"
ALLOW_MAJOR="$(env_get N8N_AUTO_UPDATE_MAJOR)"
CHANNEL="$(env_get N8N_UPDATE_CHANNEL)"
CHANNEL="${CHANNEL:-stable}"
KEEP_BACKUPS="$(env_get N8N_UPDATE_KEEP_BACKUPS)"
KEEP_BACKUPS="${KEEP_BACKUPS:-7}"

if ! [[ "$CURRENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: N8N_VERSION in .env is missing or not an exact version: '$CURRENT'"
  exit 1
fi
if [ "$CHANNEL" != "stable" ] && [ "$CHANNEL" != "beta" ]; then
  echo "ERROR: N8N_UPDATE_CHANNEL in .env must be stable or beta, not '$CHANNEL'"
  exit 1
fi
if ! [[ "$KEEP_BACKUPS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: N8N_UPDATE_KEEP_BACKUPS in .env must be a whole number of 1 or more, not '$KEEP_BACKUPS'"
  exit 1
fi
echo "channel: $CHANNEL, running: $CURRENT, new major versions: ${ALLOW_MAJOR:-false}, backups kept: $KEEP_BACKUPS"

# The OS package upgrade (unattended-upgrades) can restart Docker. Pulling or recreating
# containers at the same moment fails, so wait for it to finish first.
apt_busy() {
  command -v systemctl >/dev/null || return 1
  systemctl is-active --quiet apt-daily-upgrade.service || systemctl is-active --quiet apt-daily.service
}
if apt_busy; then
  if [ "$CHECK_ONLY" = true ]; then
    echo "note: an OS package upgrade is running now; a real run would wait for it"
  else
    echo "an OS package upgrade is running; waiting up to ${APT_WAIT_MAX}s for it to finish"
    waited=0
    while apt_busy; do
      if [ "$waited" -ge "$APT_WAIT_MAX" ]; then
        echo "SKIPPED: the OS package upgrade was still running after ${APT_WAIT_MAX}s. Will try again on the next run."
        exit 0
      fi
      sleep 30
      waited=$((waited + 30))
    done
    echo "OS package upgrade finished after ${waited}s"
  fi
fi

# Ask the registry where the channel tag points now. Downloads layers only if it moved.
docker pull -q "n8nio/n8n:$CHANNEL" >/dev/null
TARGET="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "n8nio/n8n:$CHANNEL")"
if ! [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: could not read a version from n8nio/n8n:$CHANNEL (got '$TARGET')"
  exit 1
fi

if [ "$TARGET" = "$CURRENT" ]; then
  echo "up to date ($CURRENT) - nothing to do"
  exit 0
fi
if [ "$(printf '%s\n%s\n' "$CURRENT" "$TARGET" | sort -V | tail -n 1)" = "$CURRENT" ]; then
  echo "running $CURRENT, newer than :$CHANNEL ($TARGET) - nothing to do"
  exit 0
fi
if [ "${CURRENT%%.*}" != "${TARGET%%.*}" ] && [ "$ALLOW_MAJOR" != "true" ]; then
  echo "SKIPPED: :$CHANNEL is a new major version ($CURRENT -> $TARGET)."
  echo "Read the breaking changes, then set N8N_VERSION=$TARGET by hand or N8N_AUTO_UPDATE_MAJOR=true in .env."
  exit 0
fi

# Stacks with external task runners need the runner image at the same version as n8n.
USES_RUNNERS=false
if docker compose config --images | grep -q '^n8nio/runners:'; then
  USES_RUNNERS=true
fi

if [ "$CHECK_ONLY" = true ]; then
  echo "would update $CURRENT -> $TARGET (back up the DB, set N8N_VERSION, recreate the stack)"
  exit 0
fi

echo "updating $CURRENT -> $TARGET"

# Pull the images before touching anything, so a missing image stops the update.
docker pull -q "n8nio/n8n:$TARGET" >/dev/null
if [ "$USES_RUNNERS" = true ]; then
  docker pull -q "n8nio/runners:$TARGET-distroless" >/dev/null
fi

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
  echo "stack up on $TARGET"
else
  echo "ERROR: stack not healthy on $TARGET after ${WAIT_TIMEOUT}s. Check 'docker compose ps' and logs."
  echo "To roll back: restore $BACKUP into Postgres, then set N8N_VERSION=$CURRENT in .env."
  exit 1
fi

# Housekeeping, only after a successful update. Keep the newest $KEEP_BACKUPS DB backups
# whatever their age (updates can be weeks apart, and an age limit would then leave only
# the backup just taken). File names start with a timestamp, so name order is age order.
find "$BACKUP_DIR" -maxdepth 1 -name 'n8n-db-*.sql.gz' -type f -printf '%f\n' \
  | sort -r | tail -n +"$((KEEP_BACKUPS + 1))" \
  | while IFS= read -r old; do rm -f -- "$BACKUP_DIR/$old"; echo "pruned backup: $old"; done
# Then n8n images other than the current and previous version (images still in use are
# skipped), then dangling layers.
docker image ls --format '{{.Repository}}:{{.Tag}}' \
  | grep -E '^n8nio/(n8n|runners):[0-9]' \
  | grep -vE ":($(printf '%s' "$TARGET" | sed 's/\./\\./g')|$(printf '%s' "$CURRENT" | sed 's/\./\\./g'))(-distroless)?$" \
  | xargs -r docker image rm >/dev/null 2>&1 || true
docker image prune -f

echo "update complete: $CURRENT -> $TARGET"
