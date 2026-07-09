# n8n

Self-hosted n8n in queue mode, with PostgreSQL and Redis, running behind Traefik for HTTPS.

Queue mode means work is split between a web process (the editor and webhooks) and one or more
worker processes that run your workflows. This scales better than the default single-process setup.

## Prerequisites

- Docker and Docker Compose
- Traefik running with a shared `web` external network (see the `traefik/` folder)

## Setup

1. Copy the example env file and fill in your values:
   ```bash
   cp .env.example .env
   ```

2. Create the external Docker network (skip if Traefik already made it):
   ```bash
   docker network create web
   ```

3. If you use custom CA certificates, drop them in the `pki/` folder. Otherwise leave it empty.

4. Start the stack:
   ```bash
   docker compose up -d
   ```

The editor will be at `https://<N8N_EDITOR_SUBDOMAIN>.<DOMAIN_NAME>` once Traefik has issued the
certificate.

## Running more workers

The compose file defines one worker service. To run more than one worker, use the scale flag:

```bash
docker compose up -d --scale n8n-worker=2
```

## Automatic updates

The image is pinned to the `n8nio/n8n:stable` tag, which always points at the latest stable release.
Note that pulling `:stable` and restarting does not update anything on its own, because a restart
reuses the image already on disk. You have to pull the new image and recreate the containers.

`update-n8n.sh` does exactly that, safely:

1. Checks whether `:stable` has actually moved. If not, it exits and changes nothing.
2. If it moved, it takes a compressed PostgreSQL backup into `backups/` first. n8n database
   migrations run on startup and cannot be downgraded, so this backup is your safety net.
3. Pulls the new image and recreates only the n8n containers. PostgreSQL and Redis are left alone.
4. Deletes backups older than `RETENTION_DAYS` and prunes dangling images.

Edit the config block at the top of the script to match your setup:

- `WORKERS` - how many worker replicas to keep running
- `RETENTION_DAYS` - how many days of database backups to keep
- `TIMEZONE` - set to your `GENERIC_TIMEZONE` so log and backup timestamps read in local time

Then run it daily from cron. `CRON_TZ` sets the time the job fires in your local timezone (cron
otherwise uses the server clock, which is often UTC):

```cron
CRON_TZ=Etc/UTC
0 3 * * * /path/to/n8n/update-n8n.sh
```

Output is appended to `update-n8n.log` next to the script.

## Notes

- `N8N_PROXY_HOPS` - set this to the number of reverse proxies in front of n8n. Use `1` for just
  Traefik, or `2` if you are behind Cloudflare plus Traefik.
- `local-files/` is mounted inside n8n at `/files` for use in workflows.
- `pki/` is mounted at `/opt/custom-certificates` for custom CA trust.
- Dollar signs in passwords inside `.env` must be escaped by doubling them (`$$`), because Compose
  treats a single `$` as the start of a variable.
