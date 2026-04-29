# Traefik

Traefik v3 reverse proxy with automatic HTTPS via Let's Encrypt and security hardening.

## Prerequisites

- Docker + Docker Compose
- A domain with DNS pointing to your server

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

## Exposing a service

Add these labels to any service in the `web` network:

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

- TLS 1.2+ enforced with strong cipher suites (ECDHE only)
- HTTP automatically redirects to HTTPS
- Place dynamic config files (middleware, TLS overrides) in `dynamic/`
