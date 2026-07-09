# Traefik

Traefik v3 reverse proxy with automatic HTTPS via Let's Encrypt and some sensible security defaults.

Traefik is the front door for every other service. It owns ports 80 and 443, gets certificates
automatically, redirects HTTP to HTTPS, and routes each request to the right container based on the
hostname. Set this up before any service that needs to be reachable over HTTPS.

## Prerequisites

- Docker and Docker Compose
- A domain with DNS pointing to your server

## Setup

1. Copy the example env file and fill in your values:
   ```bash
   cp .env.example .env
   ```

2. Create the external Docker network (shared with every service Traefik routes to):
   ```bash
   docker network create web
   ```

3. Create and lock the file that stores your certificates:
   ```bash
   touch acme.json && chmod 600 acme.json
   ```

4. Start Traefik:
   ```bash
   docker compose up -d
   ```

## Exposing a service

Add these labels to any service that runs on the `web` network:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.myservice.rule=Host(`myservice.example.com`)"
  - "traefik.http.routers.myservice.entrypoints=websecure"
  - "traefik.http.routers.myservice.tls.certresolver=letsencrypt"
networks:
  - web

networks:
  web:
    external: true
```

## Notes

- TLS 1.2 or higher is enforced, with strong cipher suites (ECDHE only).
- HTTP automatically redirects to HTTPS.
- The dashboard is turned off and anonymous usage reporting is disabled.
- The `dynamic/` folder is for optional extra config, such as custom middleware or TLS overrides.
  It is mounted read-only. Leave it empty if you do not need it.
