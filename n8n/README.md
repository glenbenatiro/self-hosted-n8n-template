# n8n

Self-hosted n8n with PostgreSQL, Redis (queue mode), and Traefik for HTTPS.

## Prerequisites

- Docker + Docker Compose
- Traefik running with a `web` external network

## Setup

1. Copy the example env file and fill in your values:
   ```bash
   cp .env.example .env
   ```

2. Create the external Docker network (if not already done):
   ```bash
   docker network create web
   ```

3. (Optional) Place any custom CA certificates in the `pki/` directory.

4. Start the stack:
   ```bash
   docker compose up -d
   ```

## Notes

- `N8N_PROXY_HOPS` — set to the number of reverse proxies in front of n8n (e.g. `1` for just Traefik, `2` if behind Cloudflare + Traefik)
- `local-files/` is mounted inside n8n at `/files` for use in workflows
- `pki/` is mounted at `/opt/custom-certificates` for custom CA trust
