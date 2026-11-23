# n8n

Self-hosted n8n in queue mode, with PostgreSQL and Redis, running behind Traefik for HTTPS.

Queue mode splits the work between a main process (the editor and webhooks) and a worker process that runs your workflows. Code from Code nodes runs in a separate task runner container beside the worker, as n8n recommends for production. The main process needs no runner, because every execution, manual ones included, runs on the worker.

```mermaid
flowchart LR
  traefik[Traefik] -->|web network| main[n8n-web]
  main --> redis[(Redis queue)]
  main --> pg[(Postgres)]
  redis --> worker[n8n-worker]
  worker --> pg
  worker --- workerrunner[n8n-worker-runner]
```

The runner shares a private network only with its worker, with no internet access, so code in a Code node cannot reach Postgres, Redis or anything outside. The runner image is the hardened `-distroless` variant, running as an unprivileged user with a read-only filesystem. JavaScript and Python Code nodes both work.

## Containers

Every image is pinned to an exact version, so nothing changes until you change it.

| Container | Image | What it does |
|---|---|---|
| `n8n-web` | `n8nio/n8n:<N8N_VERSION>` | The main instance: the editor, the API, webhooks and triggers. It puts each execution on the queue. |
| `n8n-worker` | `n8nio/n8n:<N8N_VERSION>` | Takes executions off the queue and runs them, manual runs from the editor included. |
| `n8n-worker-runner` | `n8nio/runners:<N8N_VERSION>-distroless` | Runs Code node code for its worker. It must be the same version as n8n, so it uses the same `N8N_VERSION`. |
| `postgres` | `postgres:18.7` | The database: workflows, encrypted credentials, execution history, and files that pass through workflows. |
| `redis` | `redis:8.10.3-alpine` | The queue between the main instance and the workers. |

Traefik, in front of n8n, lives in the `traefik/` folder (`traefik:v3.7.19`).

Queue mode is what needs Redis and a worker. Without it, n8n runs every execution inside the main instance and needs only Postgres and a runner. This template uses queue mode so heavy workflows never slow the editor down, and so you can add workers later.

## Prerequisites

- Docker and Docker Compose
- Traefik running with a shared `web` external network (see the `traefik/` folder)

## Setup

1. Copy the example env file and fill in your values. Generate `N8N_ENCRYPTION_KEY` and `N8N_RUNNERS_AUTH_TOKEN` with `openssl rand -hex 32`, and keep the file private:
   ```bash
   cp .env.example .env
   chmod 600 .env
   ```

2. Create the external Docker network (skip if Traefik already made it):
   ```bash
   docker network create web
   ```

3. Start the stack:
   ```bash
   docker compose up -d --wait
   ```

4. Open the editor at `https://<N8N_EDITOR_SUBDOMAIN>.<DOMAIN_NAME>` once Traefik has issued the certificate, and create the owner account straight away. Until you do, whoever opens the editor first can create it.

Keep a copy of `N8N_ENCRYPTION_KEY` somewhere safe outside this server. Without it, the credentials stored in the database cannot be decrypted.

## Settings

### Your values, in `.env`

`.env.example` lists them all with comments.

| Setting | What to put |
|---|---|
| `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` | The database name, user and a long random password. |
| `N8N_VERSION` | The exact n8n version to run, for example `3.3.0`. |
| `N8N_UPDATE_CHANNEL`, `N8N_AUTO_UPDATE_MAJOR`, `N8N_UPDATE_KEEP_BACKUPS` | How `update-n8n.sh` updates (see "Versions and updates"). |
| `N8N_ENCRYPTION_KEY` | `openssl rand -hex 32`. n8n encrypts stored credentials with it. Back it up. |
| `N8N_EDITOR_SUBDOMAIN`, `N8N_WEBHOOK_SUBDOMAIN`, `DOMAIN_NAME` | The editor and webhook hostnames, for example `n8n` and `hooks-n8n` on `example.com`. Both need DNS records pointing at the server. |
| `N8N_PROTOCOL` | `https`. |
| `N8N_PROXY_HOPS` | How many reverse proxies sit in front of n8n: `1` for Traefik alone, `2` for Cloudflare plus Traefik. |
| `REDIS_PASSWORD` | A long random password. |
| `N8N_RUNNERS_AUTH_TOKEN` | `openssl rand -hex 32`. Shared by each worker and its task runner. |
| `GENERIC_TIMEZONE` | Your timezone, for example `Australia/Sydney`. Schedule Trigger nodes use it. |
| `N8N_SMTP_HOST`, `N8N_SMTP_PORT`, `N8N_SMTP_USER`, `N8N_SMTP_PASS`, `N8N_SMTP_SENDER` | The mail server for invitations and password resets. |

### Set differently from n8n's defaults

`docker-compose.yml` sets these, each with a comment and a docs link. The defaults are n8n 3.3.0's.

| Setting | Value here | n8n default | Why |
|---|---|---|---|
| `DB_TYPE` | `postgresdb` | `sqlite` | Postgres, which n8n recommends for production. |
| `DB_POSTGRESDB_HOST`, `DB_POSTGRESDB_DATABASE`, `DB_POSTGRESDB_USER`, `DB_POSTGRESDB_PASSWORD` | `postgres`, then from `.env` | `localhost`, `n8n`, `postgres`, empty | Connect to the `postgres` container. |
| `EXECUTIONS_MODE` | `queue` | `regular` | Workers run the executions. |
| `QUEUE_BULL_REDIS_HOST`, `QUEUE_BULL_REDIS_PASSWORD` | `redis`, from `.env` | `localhost`, none | Connect to the `redis` container. |
| `QUEUE_HEALTH_CHECK_ACTIVE` | `true` | `false` | Workers serve the health endpoint their health check uses. |
| `N8N_RUNNERS_MODE` | `external` | `internal` (deprecated) | Code nodes run in the runner container, not inside n8n. |
| `N8N_RUNNERS_AUTH_TOKEN` | from `.env` | a random value | Shared by each worker and its runner. |
| `N8N_RUNNERS_BROKER_LISTEN_ADDRESS` (workers only) | `0.0.0.0` | `127.0.0.1` | Lets the runner container reach its worker. |
| `N8N_RUNNERS_TASK_BROKER_URI` (runner) | `http://n8n-worker:5679` | `http://127.0.0.1:5679` | Where the runner finds its worker. |
| `GENERIC_TIMEZONE` (n8n and runner) | from `.env` | `America/New_York` | Your timezone, for schedules and dates in Code nodes. |
| `N8N_ENCRYPTION_KEY` | from `.env` | generated on first start and stored in the volume | The same key on every container, in a file you back up. |
| `N8N_EDITOR_BASE_URL`, `N8N_WEBHOOK_URL` | your two hostnames | none | The URLs n8n shows in the editor and in emails. |
| `N8N_PROTOCOL` | `https` | `http` | URLs n8n builds use https. |
| `N8N_PROXY_HOPS` | from `.env` | `0` | n8n trusts the client address that Traefik passes on. |
| `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` | `60` | `30` | Running executions get a minute to finish when a container stops. |
| `N8N_PUBLIC_API_SWAGGERUI_DISABLED` | `true` | `false` | No API playground page. |
| `N8N_RESTRICT_FILE_ACCESS_TO` | `/files` | `~/.n8n-files` | File nodes only see the `local-files/` folder. |
| `N8N_EXPRESSION_ENGINE_FRONTEND` | `quickjs` | `legacy` | Expression previews in the editor run in a sandbox, which n8n strongly recommends. |
| `N8N_INVITE_LINKS_EMAIL_ONLY` | `true` | `false` | Invitation links go only by email. |
| `N8N_DIAGNOSTICS_ENABLED`, `N8N_VERSION_NOTIFICATIONS_ENABLED`, `ENABLE_A365_OBSERVABILITY_EXPORTER` | `false` | `true` | n8n sends nothing to n8n or Microsoft that it does not need. |
| `N8N_SMTP_HOST`, `N8N_SMTP_PORT`, `N8N_SMTP_USER`, `N8N_SMTP_PASS`, `N8N_SMTP_SENDER` | from `.env` | none, port 465 | Email for invitations and password resets. |
| `TZ` | from `.env` | UTC | The container's own clock, for its logs. |

Six more are set to the value n8n already uses, on purpose. `N8N_DEFAULT_BINARY_DATA_MODE=database` is the queue-mode default, pinned because it decides what a database backup contains. `N8N_BLOCK_ENV_ACCESS_IN_NODE`, `N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES`, `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS`, `N8N_GIT_NODE_DISABLE_BARE_REPOS` and `N8N_SECURE_COOKIE` are `true`, and `N8N_UNVERIFIED_PACKAGES_ENABLED` is `false`: security settings, pinned so a changed default in a future release cannot loosen them.

### Defaults kept on purpose

These are not set, so n8n's defaults apply. Add them to the shared n8n environment if they do not suit you.

| What | Default | When to change it |
|---|---|---|
| Code node time limit | 60 seconds (`N8N_RUNNERS_TASK_TIMEOUT`) | If a Code node needs longer. Set it on the n8n containers and on the runner, which enforces it too. |
| Execution history | Kept 14 days or 10,000 executions, then pruned with its files (`EXECUTIONS_DATA_MAX_AGE` in hours, `EXECUTIONS_DATA_PRUNE_MAX_COUNT`) | Lower it if the database grows too big for the disk. |
| Workflow time limit | None (`EXECUTIONS_TIMEOUT=-1`) | Set one if a stuck workflow could hold a worker forever. Workflows can set their own limit up to `EXECUTIONS_TIMEOUT_MAX` (1 hour). |
| Executions at once | 10 per worker | Add a worker before raising it. |
| Database connections | 2 per n8n process (`DB_POSTGRESDB_POOL_SIZE`) | Only if n8n reports waiting for connections under load. |
| Compression node limits | 256 MiB and 1,000 entries per archive | Raise them if you unpack bigger archives. |
| SSRF protection | Off (`N8N_SSRF_PROTECTION_ENABLED`) | Turn it on to stop HTTP Request nodes reaching private addresses (Postgres, Redis, your own network). List any internal hosts your workflows call in its allow list first. |
| Metrics endpoint | Off (`N8N_METRICS`) | If you turn it on, block `/metrics` in Traefik first, as is done for the API spec file: it would otherwise be public. |
| Public API | On, with an API key | Set `N8N_PUBLIC_API_DISABLED=true` if nothing uses it. |
| Workflow templates library | On, loaded from n8n's servers (`N8N_TEMPLATES_ENABLED`) | Set it to `false` if nobody uses it. |
| Email encryption | Implicit TLS, for port 465 (`N8N_SMTP_SSL`) | For port 587, set `N8N_SMTP_SSL` to `"false"`. |
| Two-factor sign-in | Available to every user (`N8N_MFA_ENABLED`) | Leave it on. |

## Versions and updates

n8n and its task runner image are pinned to the same exact version, `N8N_VERSION` in `.env`. The runner image must always match n8n, so change the version only through `.env`, never in the compose file. This template runs n8n 3.3.0.

`update-n8n.sh` updates in two ways, both with a backup and a coordinated restart:

- **On its own, daily from cron:** it moves to the newest release on an n8n update channel. n8n publishes two: `stable` is the release for production use, and `beta` is the newest release, which may be unstable. Pick one per server with `N8N_UPDATE_CHANNEL`.
- **To an exact version, by hand:** `./update-n8n.sh --to 3.3.1`. Use it for a version no channel points at, and to move to a new major version on purpose.

When this was written (November 2026), n8n still published 3.x as early access releases, and both channels pointed at 2.x. Until n8n marks a 3.x release stable, the daily run on a 3.x server changes nothing, so watch for new 3.x releases (the [release notes](https://docs.n8n.io/changelog/release-notes) have an RSS feed, and so do the [GitHub releases](https://github.com/n8n-io/n8n/releases)) and apply them with `--to`. Once `stable` moves to 3.x, the daily run takes over again.

The script is the same on every server; every per-server choice lives in `.env`:

| `.env` setting | Default | What it does |
|---|---|---|
| `N8N_UPDATE_CHANNEL` | `stable` | Follow `n8nio/n8n:stable` or `n8nio/n8n:beta`. |
| `N8N_AUTO_UPDATE_MAJOR` | `false` | Set to `true` to let the daily run move to a new major version too. |
| `N8N_UPDATE_KEEP_BACKUPS` | `7` | How many database backups to keep, newest first. |
| `N8N_VERSION` | (required) | The exact version running. The script updates this line; you only set it by hand when you first install or roll back. |

Each run:

1. Waits if an OS package upgrade (unattended-upgrades) is running, because it can restart Docker. After an hour it skips this run.
2. Reads the target: the version the channel tag points at, or the one given with `--to`. If the channel's version is not newer than `N8N_VERSION`, it exits and changes nothing. It never moves to an older version, so switching a server from `beta` back to `stable` takes effect once `stable` catches up.
3. On the daily run, skips a new major version (for example 3.x to 4.x) unless `N8N_AUTO_UPDATE_MAJOR=true`. Major versions have breaking changes, so read them and check **Settings > Migration Report** in n8n first.
4. Pulls the new n8n image and the matching runner image. Then it logs the newest database migration and takes a compressed PostgreSQL backup into `backups/`, readable only by its owner. n8n runs database migrations when it starts, so this backup and that migration name are what a rollback needs (see "Roll back an update").
5. Stops every n8n container: workers first, which finish running executions while their task runners are still up, then the main instance, then the runners. n8n asks for this in queue mode, so an old and a new version never run against the database at the same time. Webhooks get no answer for the minute or so this takes.
6. Writes the new `N8N_VERSION` into `.env`, starts the stack and waits for it to come up (every container healthy, where it has a health check).
7. Keeps the newest `N8N_UPDATE_KEEP_BACKUPS` backups, whatever their age, and removes old n8n images, keeping the previous version. It removes only n8n's own images, so other projects on the same server are untouched. This only happens after a successful update.

`update-n8n.sh --check` (with or without `--to`) prints the target, the running version and what a run would do, without changing the stack. Log and backup timestamps use `GENERIC_TIMEZONE` from `.env`. The settings at the top of the script (`LOG_MAX_BYTES`, `WAIT_TIMEOUT`, `APT_WAIT_MAX`) rarely need changing.

Run it daily from cron. Cron uses the server's timezone (`timedatectl` shows it). Pick a time after the server's automatic OS upgrade and any reboot that follows it, and outside the hours your workflows are busy. Ubuntu runs that upgrade around 06:00 by default; check yours with `systemctl list-timers apt-daily-upgrade.timer`. For example, on a server whose OS upgrade runs at 03:00:

```cron
0 4 * * * /path/to/n8n/update-n8n.sh
```

Output is appended to `update-n8n.log` next to the script, which rotates to `update-n8n.log.1` when it grows past `LOG_MAX_BYTES`.

The script does not read release notes for you. n8n recommends reading them for every version you skip over.

## Postgres and Redis

Postgres and Redis are pinned to exact versions in `docker-compose.yml`, so nothing changes under you. Bump them deliberately:

- A new minor or patch release of the same major version is a drop-in update: change the tag and run `docker compose up -d --wait`. n8n asks you to run the latest minor release of your Postgres major version.
- n8n supports the two newest Postgres major versions plus one older one ([supported versions](https://docs.n8n.io/deploy/host-n8n/configure-n8n/choose-n8ns-database#supported-postgresql-versions)). Check that page before you move to a new major version.
- A new Postgres major version cannot read the data folder of an older one. If you only change the tag, Postgres refuses to start with `database files are incompatible with server`. Your data stays safe, but n8n is down. Use `upgrade-postgres.sh` instead, below.

### Upgrade Postgres to a new major version

`upgrade-postgres.sh` does the upgrade by dump and restore and keeps the old data for a quick rollback:

1. Set the new image in `docker-compose.yml`, for example `postgres:18.7`. Do not run `docker compose up` yet. Keep the `PGDATA: /var/lib/postgresql/data` line: Postgres 18 images moved their default data folder, and the script refuses to run without it.
2. Check what it will do. This pulls the new image and changes nothing else:
   ```bash
   ./upgrade-postgres.sh --check
   ```
3. Run it. n8n is down for a few minutes, longer for a large database:
   ```bash
   ./upgrade-postgres.sh
   ```

It stops n8n, counts the rows in every table, and dumps the database and its roles with the old Postgres. It copies the old data volume to a second volume named after the old major version (for example `n8n_postgres_data-pg17`), restores into the new Postgres, checks every table has the same number of rows, refreshes the planner statistics, and starts the stack. If anything fails before the data volume is emptied, it starts the stack again on the old Postgres. If it fails after that, it prints the exact commands to go back. Once n8n has run well for a few days, remove the old volume and the dump files it names.

### Redis

Redis holds the queue of executions waiting for a worker. It writes every change to an append-only file in its volume, so queued jobs survive a restart: if Redis loses them, n8n marks those executions as crashed and does not run them again.

## Back up

A full backup has three parts ([backup and restore](https://docs.n8n.io/deploy/host-n8n/keep-n8n-running/backup-and-restore)):

1. **The database.** `update-n8n.sh` takes one before every update. To take one by hand:
   ```bash
   (umask 077; docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' | gzip > "backups/n8n-db-$(date +%Y%m%d-%H%M%S)-manual.sql.gz")
   ```
   Files that pass through workflows (binary data) are stored in the database too, so they are in this dump.
2. **The `.env` file**, above all `N8N_ENCRYPTION_KEY`. Without it, the credentials in the database cannot be decrypted.
3. **The `n8n_data` volume** (`/home/node/.n8n` in the containers). It holds a `config` file with the encryption key, and installed community nodes.

Backups in `backups/` sit on the same disk as the live data, so they do not protect against losing the server. Copy them somewhere else as well.

## Roll back an update

n8n changes the database when a new version starts, and an older version may not work with the changed database. So rolling back means returning the database to its state before the update, then starting the older version. `update-n8n.log` names the backup, the previous version and the newest migration before the update.

1. Stop every n8n container, task runners included. Keep Postgres and Redis running:
   ```bash
   docker compose stop n8n-web n8n-worker n8n-worker-runner
   ```
   Add `n8n-worker-2` and `n8n-worker-2-runner` if you use the override file.
2. Return the database to its state before the update, in one of two ways:
   - **Revert the migrations.** This keeps everything that happened since the update. Run `n8n db:revert` with the newer image, as a one-off container, once per migration the update added, until the newest migration matches the one in the log. n8n's [update guide](https://docs.n8n.io/deploy/host-n8n/keep-n8n-running/update-n8n) explains it. `db:revert` exits with status 0 even when it does nothing, so read its output each time.
   - **Restore the backup.** This loses everything that happened since the backup. Check the backup file is there first, then replace the database with it:
     ```bash
     docker compose exec -T postgres sh -c 'dropdb -U "$POSTGRES_USER" "$POSTGRES_DB" && createdb -U "$POSTGRES_USER" "$POSTGRES_DB"'
     gunzip -c backups/<backup file>.sql.gz | docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q' > /dev/null
     ```
3. Set `N8N_VERSION` in `.env` back to the previous version and start the stack. The runner image follows the same variable, so it goes back too:
   ```bash
   docker compose up -d --wait
   ```

On n8n 3.x, a downgrade after n8n has written data with its rotatable encryption key needs the restore, not `db:revert`: older versions cannot decrypt that data.

## Move an instance from n8n 2.x to 3.x

This is how an existing 2.x instance, whether built from an older version of this template or not, moves onto this stack and n8n 3.3.0. Read [the v3.0 breaking changes](https://docs.n8n.io/changelog/v30-breaking-changes) first.

1. On the instance, open **Settings > Migration Report** and fix what it lists for your workflows: removed legacy nodes (Function, Cron, Read Binary File and others), Slack Trigger credentials without a signing secret, and Code nodes that run longer than a minute, the new default limit.
2. Take this template's `docker-compose.yml`, or `git pull` if the server runs from a clone, and add any new settings to `.env` (the root README shows how to list missing ones). `N8N_RUNNERS_AUTH_TOKEN` is new for instances that ran task runners inside n8n. Do not run `docker compose up` yet: on 2.x, a main instance without the 2.x-only `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true` would run manual executions itself, with no runner for Code nodes.
3. Move to 3.x in one step. The script backs up the database, stops n8n, sets `N8N_VERSION`, and starts n8n 3.3.0 with its runner:
   ```bash
   ./update-n8n.sh --to 3.3.0
   ```
4. Check the editor, run a workflow that has a Code node, and watch the next scheduled runs.

On its first start, n8n 3.x renames the storage folder `~/.n8n/binaryData` to `~/.n8n/storage` inside the `n8n_data` volume, and turns on encryption key rotation. After that, going back to 2.x needs the database restore in "Roll back an update", because 2.x cannot read data encrypted with a rotated key.

## Running more workers

The compose file defines one worker with one task runner, which is plenty for most instances. Each worker needs its own runner, so workers cannot be added with `--scale`. To run a second worker, use the ready-made override file:

```bash
cp docker-compose.override.example.yml docker-compose.override.yml
docker compose up -d --wait
```

Docker Compose loads `docker-compose.override.yml` automatically, and it is git-ignored, so `git pull` and `update-n8n.sh` keep your extra worker. It adds `n8n-worker-2` with its own runner on its own internal network, and its own event log file, because both workers share the `n8n_data` volume. For a third worker, repeat the pattern in the same file with `-3` names.

## Notes

- `N8N_PROXY_HOPS` is the number of reverse proxies in front of n8n. Use `1` for just Traefik, or `2` if you are behind Cloudflare plus Traefik (with Traefik trusting Cloudflare's forwarded headers, see the Traefik README).
- The webhook hostname serves only what n8n serves there: webhooks, forms and MCP Server Trigger nodes (`/webhook*`, `/form*`, `/mcp/`, `/mcp-test/`). The editor and its `/rest` API are not reachable on it.
- `local-files/` is mounted inside n8n at `/files`. The Read/Write Files from Disk node can only use that folder (`N8N_RESTRICT_FILE_ACCESS_TO`).
- Custom CA certificates: add `- ./pki:/opt/custom-certificates` to the n8n volumes and put the certificates in `pki/`. The folder must be writable by the container's `node` user (UID 1000), because n8n's entrypoint indexes the certificates there on start.
- The Execute Command and Local File Trigger nodes stay disabled, which is n8n's default since 2.0.
- The public REST API is on, but its Swagger page (`/api/v1/docs`) is off (`N8N_PUBLIC_API_SWAGGERUI_DISABLED`), and Traefik answers 403 for its spec file (`/api/v1/openapi.yml`), which n8n serves whenever the public API is on. If nothing uses the API, add `N8N_PUBLIC_API_DISABLED: "true"` to the shared n8n environment in `docker-compose.yml`.
- The health check endpoints `/healthz` and `/healthz/readiness` answer on the editor hostname without a login, which suits an uptime monitor. They show only whether n8n is up.
- n8n sends nothing it does not need to: anonymous usage data, update notices and the Microsoft Agent 365 trace export are off. The workflow templates library stays on and loads from n8n's servers; set `N8N_TEMPLATES_ENABLED` to `"false"` if nobody uses it.
- The editor evaluates expression previews in a QuickJS sandbox (`N8N_EXPRESSION_ENGINE_FRONTEND`), which n8n strongly recommends.
- The task broker, which hands Code node work to a runner, listens on the network only on workers. The runner gets the same timezone as n8n, so dates in Code nodes match.
- JavaScript Code nodes can import only `crypto` and `moment`, and Python Code nodes no modules at all, which is the runner image's own setting. Allowing more takes a task runner configuration file mounted into the runner, not environment variables on n8n ([enable modules](https://docs.n8n.io/deploy/host-n8n/configure-n8n/basic-configuration/configuration-examples/enable-modules-in-code-node)).
- Schedule Trigger nodes that repeat every few seconds or minutes keep a steady interval from when the workflow was published, instead of lining up with the clock ([durable scheduler](https://docs.n8n.io/deploy/host-n8n/configure-n8n/durable-scheduler), the default since n8n 2.45.0).
- Dollar signs in passwords inside `.env` must be escaped by doubling them (`$$`), because Compose treats a single `$` as the start of a variable.
