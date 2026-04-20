# Traefik

Traefik v3 reverse proxy with automatic HTTPS via Let's Encrypt, a secured dashboard, and security hardening.

## Prerequisites

- Docker + Docker Compose

## Setup

1. Copy the example env file and fill in your values:
   ```bash
   cp .env.example .env
   ```

2. Create the external Docker network (shared with all services):
   ```bash
   docker network create web
   ```

3. Create and lock the ACME certificate storage file:
   ```bash
   touch acme.json && chmod 600 acme.json
   ```

4. Start Traefik:
   ```bash
   docker compose up -d
   ```

## Notes

- `dynamic/` directory is watched for dynamic config files (middleware, TLS options, etc.)
- Dashboard is protected by basic auth — generate credentials with `htpasswd -nB username`
- TLS 1.2+ enforced with strong cipher suites
