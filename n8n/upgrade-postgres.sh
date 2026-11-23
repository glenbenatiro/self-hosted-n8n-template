#!/usr/bin/env bash
#
# upgrade-postgres.sh - move the stack's Postgres to a new major version (for example 17 to 18).
#
# A new Postgres major version cannot open a data folder written by an older one. If you only
# change the image tag, Postgres refuses to start ("database files are incompatible with
# server"). Your data stays safe, but n8n is down. This script does the upgrade by dump and
# restore, one of the methods in the PostgreSQL upgrade guide:
#
#   1. Pulls the new image and checks the versions, the volume and the free disk space.
#   2. Stops every other service, so nothing writes to the database.
#   3. Counts the rows in every table, then dumps the database and its roles with the old
#      Postgres, which is still running.
#   4. Copies the old data volume to a second volume, <volume>-pg<old major>, and leaves that
#      copy untouched, so a rollback takes seconds.
#   5. Empties the data volume, starts the new Postgres on it, and restores the dump.
#   6. Checks every table has the same number of rows, refreshes the planner statistics, and
#      starts the whole stack.
#
# How to use it:
#   1. Set the new Postgres image in docker-compose.yml. Do not run `docker compose up` yet.
#   2. ./upgrade-postgres.sh --check   pulls the new image, prints what it would do, and
#                                      changes nothing else.
#   3. ./upgrade-postgres.sh           does it. n8n is down for a few minutes.
#
# If it fails before the data volume is emptied, the script starts the stack again on the old
# Postgres, as it was. If it fails after that, it prints the exact rollback commands.
#
set -euo pipefail
# Everything this script writes is a backup holding every n8n credential: owner-only.
umask 077

CHECK_ONLY=false
case "${1:-}" in
  "") ;;
  --check) CHECK_ONLY=true ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

# Resolve the stack directory from this script's own location (no hardcoded path).
STACK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$STACK_DIR/backups"
ENV_FILE="$STACK_DIR/.env"
cd "$STACK_DIR"

# Never run at the same time as update-n8n.sh, which also recreates the stack.
exec 9>"$STACK_DIR/.update-n8n.lock"
flock -n 9 || { echo "update-n8n.sh or upgrade-postgres.sh is already running; try again later" >&2; exit 1; }

log() { echo "[$(date '+%F %T')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Read one value from .env, without sourcing it (it holds secrets and may contain $$).
env_get() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | sed -e 's/^["'\'']//' -e 's/["'\'']$//'
}
TZ="$(env_get GENERIC_TIMEZONE)"
export TZ="${TZ:-Etc/UTC}"
PG_USER="$(env_get POSTGRES_USER)"
PG_DB="$(env_get POSTGRES_DB)"

# Run a Postgres client tool inside the postgres container as the superuser from .env, over
# the local socket, so no password crosses the command line: pg <tool> [args...]
pg() { docker exec -i "$PG_CID" sh -c 'tool=$1; shift; exec "$tool" -U "$POSTGRES_USER" "$@"' sh "$@"; }

# The named volume mounted at a path in a container.
volume_at() {
  docker inspect --format "{{range .Mounts}}{{if eq .Destination \"$2\"}}{{.Name}}{{end}}{{end}}" "$1"
}

# --- what is running, and what docker-compose.yml asks for ------------------------------
PG_CID="$(docker compose ps -q postgres)"
[ -n "$PG_CID" ] && [ "$(docker inspect --format '{{.State.Running}}' "$PG_CID")" = true ] \
  || die "the postgres service is not running. Start the stack on the old version first."

OLD_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$PG_CID")"
NEW_IMAGE="$(docker compose config --images postgres)"
[ -n "$NEW_IMAGE" ] || die "no image found for the postgres service in docker-compose.yml"

PGDATA_DIR="$(docker exec "$PG_CID" sh -c 'echo "$PGDATA"')"
VOLUME="$(volume_at "$PG_CID" "$PGDATA_DIR")"
[ -n "$VOLUME" ] || die "no named volume is mounted at $PGDATA_DIR in the postgres container"

# The new container must keep its data in the same place. Postgres 18 images moved the default
# data folder, so without PGDATA the new server would write to a throwaway volume instead.
NEW_CONFIG="$(docker compose config postgres)"
NEW_PGDATA="$(printf '%s\n' "$NEW_CONFIG" | sed -n 's/^ *PGDATA: *//p' | tr -d "\"'")"
[ "$NEW_PGDATA" = "$PGDATA_DIR" ] \
  || die "set PGDATA: $PGDATA_DIR on the postgres service in docker-compose.yml (it is '${NEW_PGDATA:-not set}')"
printf '%s\n' "$NEW_CONFIG" | grep -qE "^ *target: $PGDATA_DIR\$" \
  || die "docker-compose.yml no longer mounts a volume at $PGDATA_DIR for postgres"

OLD_MAJOR=$(( $(pg psql -d postgres -Atc 'show server_version_num') / 10000 ))

log "pulling $NEW_IMAGE"
docker pull -q "$NEW_IMAGE" > /dev/null
# Prints "postgres (PostgreSQL) 18.1", sometimes followed by the distribution's package version.
NEW_VERSION="$(docker run --rm --entrypoint postgres "$NEW_IMAGE" --version | awk '{print $3}')"
NEW_MAJOR="${NEW_VERSION%%.*}"
[[ "$NEW_MAJOR" =~ ^[0-9]+$ ]] || die "could not read the version of $NEW_IMAGE (got '$NEW_VERSION')"

BACKUP_VOLUME="$VOLUME-pg$OLD_MAJOR"
echo "running: $OLD_IMAGE (major $OLD_MAJOR), data volume $VOLUME"
echo "target:  $NEW_IMAGE ($NEW_VERSION)"

if [ "$NEW_MAJOR" -eq "$OLD_MAJOR" ]; then
  echo "Same major version, so no dump is needed: run 'docker compose up -d --wait'."
  exit 0
fi
[ "$NEW_MAJOR" -gt "$OLD_MAJOR" ] || die "the target is older than the running version. Postgres cannot move down a major version."
! docker volume inspect "$BACKUP_VOLUME" > /dev/null 2>&1 \
  || die "the rollback volume $BACKUP_VOLUME already exists. Check what is in it, and remove it yourself if it is no longer needed."

# Room for the dump and a full copy of the data volume, with a margin.
VOLUME_BYTES="$(docker run --rm -v "$VOLUME:/v:ro" --entrypoint du "$OLD_IMAGE" -sb /v | cut -f1)"
FREE_BYTES="$(df -B1 --output=avail "$(docker info --format '{{.DockerRootDir}}')" | tail -n 1)"
NEED_BYTES=$((VOLUME_BYTES * 3))
echo "disk:    volume $((VOLUME_BYTES / 1048576)) MiB, free $((FREE_BYTES / 1048576)) MiB, needs about $((NEED_BYTES / 1048576)) MiB"
[ "$FREE_BYTES" -ge "$NEED_BYTES" ] || die "not enough free disk space"

OTHER_SERVICES="$(docker compose ps --services --status running | grep -vx postgres | tr '\n' ' ' || true)"
if [ "$CHECK_ONLY" = true ]; then
  echo "would stop: ${OTHER_SERVICES:-nothing else}"
  echo "then dump the database, copy $VOLUME to $BACKUP_VOLUME, restore into Postgres $NEW_VERSION, and start the stack."
  exit 0
fi

# --- on any failure, undo what is safe to undo -------------------------------------------
# STAGE says how far the script got: "stopped" (old data untouched), "emptied", or "finished".
STAGE=none
on_exit() {
  local rc=$?
  [ "$rc" -ne 0 ] || return 0
  case "$STAGE" in
    stopped)
      echo "The upgrade stopped before any data changed. Starting the stack again on Postgres $OLD_MAJOR." >&2
      [ "${BACKUP_CREATED:-false}" = false ] || docker volume rm "$BACKUP_VOLUME" > /dev/null || true
      # `start` restarts the existing containers as they were, without recreating them.
      # shellcheck disable=SC2086
      docker compose start postgres $OTHER_SERVICES || true
      ;;
    emptied)
      cat >&2 <<EOF

The upgrade failed after the data volume was emptied. Nothing is lost:
  - $BACKUP_VOLUME holds the old data folder, exactly as it was.
  - $PREFIX.dump holds the database.
To go back to Postgres $OLD_MAJOR:
  1. In docker-compose.yml, set the postgres image back to $OLD_IMAGE.
  2. docker compose stop
  3. docker run --rm -v $VOLUME:/data --entrypoint sh $OLD_IMAGE -c 'find /data -mindepth 1 -delete'
  4. docker run --rm -v $BACKUP_VOLUME:/from:ro -v $VOLUME:/to --entrypoint sh $OLD_IMAGE -c 'cp -a /from/. /to/'
  5. docker compose up -d --wait
EOF
      ;;
  esac
}
trap on_exit EXIT

# --- 1. stop everything that writes, then count and dump ---------------------------------
STAMP="$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
PREFIX="$BACKUP_DIR/pg-upgrade-$STAMP-pg$OLD_MAJOR"

STAGE=stopped
log "stopping: ${OTHER_SERVICES:-nothing else}"
# shellcheck disable=SC2086
[ -z "$OTHER_SERVICES" ] || docker compose stop $OTHER_SERVICES

# One exact row count per table, in every schema the restore touches.
COUNT_SQL="select table_schema || '.' || table_name || ' ' ||
  (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text
  from information_schema.tables
  where table_type = 'BASE TABLE' and table_schema not in ('pg_catalog', 'information_schema')
  order by 1"
count_rows() { pg psql -d "$PG_DB" -v ON_ERROR_STOP=1 -Atc "$COUNT_SQL"; }

count_rows > "$PREFIX-counts.txt"
log "counted the rows in $(wc -l < "$PREFIX-counts.txt") tables"

log "dumping the roles and the database with Postgres $OLD_MAJOR"
pg pg_dumpall --roles-only > "$PREFIX-roles.sql"
pg pg_dump -d "$PG_DB" --format=custom > "$PREFIX.dump"
# A custom-format dump that pg_restore can list is complete and readable.
docker run --rm -i --entrypoint pg_restore "$NEW_IMAGE" --list < "$PREFIX.dump" > /dev/null \
  || die "the dump cannot be read back"
log "dump written: $PREFIX.dump ($(stat -c '%s' "$PREFIX.dump") bytes)"

# --- 2. keep the old data, untouched, in a second volume ---------------------------------
log "stopping Postgres $OLD_MAJOR and copying $VOLUME to $BACKUP_VOLUME"
docker compose stop postgres
docker volume create --label "upgrade-postgres.from=$OLD_IMAGE" "$BACKUP_VOLUME" > /dev/null
BACKUP_CREATED=true
docker run --rm -v "$VOLUME:/from:ro" -v "$BACKUP_VOLUME:/to" --entrypoint sh "$OLD_IMAGE" -c 'cp -a /from/. /to/'
listing() { docker run --rm -v "$1:/v:ro" --entrypoint sh "$OLD_IMAGE" -c 'cd /v && find . -type f -exec du -b {} + | sort'; }
[ "$(listing "$VOLUME")" = "$(listing "$BACKUP_VOLUME")" ] || die "the copy in $BACKUP_VOLUME does not match $VOLUME"

# --- 3. start the new Postgres on the emptied volume and restore -------------------------
STAGE=emptied
log "emptying $VOLUME"
docker run --rm -v "$VOLUME:/data" --entrypoint sh "$OLD_IMAGE" -c 'find /data -mindepth 1 -delete'

log "starting Postgres $NEW_VERSION on the empty volume"
docker compose up -d --wait postgres
PG_CID="$(docker compose ps -q postgres)"
[ "$(volume_at "$PG_CID" "$PGDATA_DIR")" = "$VOLUME" ] \
  && [ "$(docker exec "$PG_CID" sh -c 'echo "$PGDATA"')" = "$PGDATA_DIR" ] \
  || die "the new postgres container does not keep its data in $VOLUME"

log "restoring the roles"
# The new server already has the superuser from .env, so skip creating it again.
sed -E "/^CREATE ROLE \"?$PG_USER\"?;\$/d" "$PREFIX-roles.sql" | pg psql -d postgres -v ON_ERROR_STOP=1 -q > /dev/null

log "restoring the database"
# Recreate the database from the dump, so its owner, settings and grants come back too.
pg dropdb "$PG_DB"
pg pg_restore -d postgres --create --exit-on-error < "$PREFIX.dump"

log "checking the row counts"
count_rows > "$PREFIX-counts-after.txt"
diff -u "$PREFIX-counts.txt" "$PREFIX-counts-after.txt" || die "the row counts differ after the restore"
log "all $(wc -l < "$PREFIX-counts.txt") tables match"

# A restore carries no planner statistics. Without them, queries are slow until autovacuum runs.
log "refreshing the planner statistics"
pg vacuumdb --all --analyze-in-stages --quiet

# --- 4. start the stack ------------------------------------------------------------------
log "starting the stack"
docker compose up -d --wait
STAGE=finished

log "done: Postgres $OLD_MAJOR -> $NEW_VERSION"
cat <<EOF
Kept for a rollback. Remove them yourself once n8n has run well for a few days:
  - the volume $BACKUP_VOLUME   (docker volume rm $BACKUP_VOLUME)
  - $PREFIX.dump and $PREFIX-roles.sql
EOF
