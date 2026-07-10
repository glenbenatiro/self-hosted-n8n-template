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
- **Security headers** (HSTS, `nosniff`, `X-Frame-Options: DENY`) are applied to every router by a
  shared middleware at the entrypoint — `dynamic/security-headers.yml`. No per-service header
  labels needed.
- The dashboard is turned off and anonymous usage reporting is disabled.
- The Traefik image is **pinned** (`traefik:v3.7.7`) — bump it deliberately rather than tracking a
  floating tag.
- The ACME contact email is set **directly in `traefik.yml`**, not in `.env` — Traefik does not
  expand environment variables in its static config file.
- The `dynamic/` folder holds file-provider config loaded automatically (mounted read-only):
  `security-headers.yml` (on by default) and `cloudflare.yml` (opt-in — see below).

## Behind Cloudflare (optional hardening)

If this origin sits behind the Cloudflare proxy, you can lock it down so only Cloudflare can reach
it, and make certificate renewal independent of any inbound port:

1. **DNS-01 certificates.** In `traefik.yml`, comment out the `httpChallenge` block and uncomment
   the `dnsChallenge` (Cloudflare) block. Create a Cloudflare API token scoped to `Zone:Read` +
   `DNS:Edit`, put it in `.env` as `CF_DNS_API_TOKEN`, and uncomment the `environment:` block in
   `docker-compose.yml`. Renewal then needs no inbound port 80.
2. **Origin allow-list.** Uncomment `- "cf-only@file"` on the `websecure` entrypoint in
   `traefik.yml` (defined in `dynamic/cloudflare.yml`). Non-Cloudflare requests get 403.
3. **Edge firewall + IPv4 bind.** Restrict inbound 80/443 to Cloudflare's IP ranges at your cloud
   firewall, and bind Traefik's ports IPv4-only (`0.0.0.0:80:80` / `0.0.0.0:443:443`) if your
   origin has no public IPv6 route from Cloudflare.

Full walkthrough — firewall ranges, verifying from an external vantage, and the gotchas — in
[glenbenatiro/vps-hardening](https://github.com/glenbenatiro/vps-hardening/blob/main/HARDENING.md)
§10.8–10.10.

> Do **not** enable steps 2–3 unless you are actually behind Cloudflare — you will lock yourself
> (and everyone else) out.
