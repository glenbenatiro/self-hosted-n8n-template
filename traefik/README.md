# Traefik

Traefik v3 reverse proxy with automatic HTTPS via Let's Encrypt and some sensible security defaults.

Traefik is the front door for every other service. It owns ports 80 and 443, gets certificates automatically, redirects HTTP to HTTPS, and routes each request to the right container based on the hostname. Set this up before any service that needs to be reachable over HTTPS.

## Prerequisites

- Docker and Docker Compose
- A domain with DNS pointing to your server

## Setup

1. Pick the static configuration that matches your server, copy it to `traefik.yml`, and set your ACME contact email in it:
   - `traefik.example.yml` for a server reached directly. Certificates use the HTTP-01 challenge, so port 80 must be reachable from the internet.
   - `traefik.cloudflare.example.yml` for a server behind the Cloudflare proxy. See [Behind Cloudflare](#behind-cloudflare).
   ```bash
   cp traefik.example.yml traefik.yml
   ```

2. Copy the example env file and fill in your values:
   ```bash
   cp .env.example .env
   chmod 600 .env
   ```

3. Create the external Docker network (shared with every service Traefik routes to):
   ```bash
   docker network create web
   ```

4. Create and lock the file that stores your certificates:
   ```bash
   touch acme.json && chmod 600 acme.json
   ```

5. Start Traefik:
   ```bash
   docker compose up -d --wait
   ```

6. Rotate the access log daily (needs root, because Traefik writes the log as root):
   ```bash
   sed "s#/path/to/traefik#$PWD#" logrotate.conf | sudo tee /etc/logrotate.d/traefik
   sudo logrotate --debug /etc/logrotate.d/traefik
   ```

`traefik.yml`, `.env`, `acme.json` and `logs/` hold your own settings, certificates and logs. They are git-ignored, so `git pull` never overwrites them. After pulling a new version of this repo, compare your `traefik.yml` with the example you started from (`diff traefik.yml traefik.cloudflare.example.yml`) and copy over anything new.

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

- TLS 1.2 or higher is enforced, with ECDHE cipher suites only, and handshakes that do not name a configured host are refused (`sniStrict`). These are in `dynamic/tls.yml`: Traefik ignores TLS options in the static `traefik.yml`.
- HTTP automatically redirects to HTTPS.
- Security headers (HSTS for 2 years, `nosniff`, `X-Frame-Options: DENY`) are applied to every router by a shared middleware at the entrypoint, in `dynamic/security-headers.yml`. No per-service header labels are needed.
- The dashboard is turned off and anonymous usage reporting is disabled.
- Ports are published on IPv4 only. Docker publishes a bare `80:80` on IPv6 too, and Docker's port rules skip the host firewall.
- The access log goes to `logs/access.log` as JSON. Authorization and cookie headers are never logged.
- The Traefik image is pinned (`traefik:v3.7.14`). Bump it deliberately rather than tracking a floating tag.
- The `dynamic/` folder holds file-provider config, loaded automatically and mounted read-only: `tls.yml`, `security-headers.yml` and `cloudflare.yml` (only used by the Cloudflare configuration).

## Behind Cloudflare

If this server sits behind the Cloudflare proxy, `traefik.cloudflare.example.yml` locks it down so only Cloudflare can reach it, and makes certificate renewal independent of any inbound port:

1. **DNS-01 certificates.** Create a Cloudflare API token scoped to `Zone:Read` and `DNS:Edit` and put it in `.env` as `CF_DNS_API_TOKEN`. Renewal then needs no inbound port 80.
2. **Origin allow-list.** The `cf-only` middleware (`dynamic/cloudflare.yml`) returns 403 to any request that does not come from a Cloudflare edge IP.
3. **Real visitor IPs.** Traefik trusts the `X-Forwarded-For` header only from Cloudflare's ranges, so services see the visitor's IP rather than a Cloudflare edge IP. For n8n, set `N8N_PROXY_HOPS=2`.
4. **Edge firewall.** Restrict inbound 80/443 to Cloudflare's IP ranges at your cloud firewall as well.

Cloudflare's ranges appear twice, in `dynamic/cloudflare.yml` and in `forwardedHeaders.trustedIPs` in `traefik.cloudflare.example.yml`. Check them against <https://www.cloudflare.com/ips-v4> and <https://www.cloudflare.com/ips-v6> now and then, and keep both lists in sync.

Full walkthrough, with firewall ranges, testing from an outside machine and the gotchas, in [glenbenatiro/vps-hardening](https://github.com/glenbenatiro/vps-hardening/blob/main/HARDENING.md) §10.8-10.10.

> Do **not** use the Cloudflare configuration unless you are actually behind Cloudflare: it returns 403 to everyone else, including you.
