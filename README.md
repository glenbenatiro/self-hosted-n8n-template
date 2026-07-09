# docker-compose-templates

Docker Compose templates for self-hosting services on a single VPS. These are the setups I actually
run in production, not toy examples. The n8n stack has been running this way for about a year.

Each service lives in its own folder with its own `docker-compose.yml`, `.env.example`, and README.
Secrets and config are read from a `.env` file that is never committed. Domains, emails, and
passwords are all pulled from environment variables, so nothing personal is baked into the files.

## What is inside

- `traefik/` - Traefik v3 reverse proxy. Terminates HTTPS with automatic Let's Encrypt
  certificates and routes traffic to your other services. Set this up first.
- `n8n/` - Self-hosted n8n in queue mode, with PostgreSQL and Redis, sitting behind Traefik.
  Includes an optional script to keep n8n updated automatically.

## How it fits together

Traefik is the front door. It owns ports 80 and 443 and shares a Docker network called `web` with
every service it routes to. Each service (like n8n) joins that `web` network and tells Traefik how
to route to it using labels. The services themselves publish no public ports.

So the order is:

1. Set up `traefik/` and create the shared `web` network.
2. Set up `n8n/` (or any other service) and let Traefik route to it.

## Prerequisites

- A VPS with Docker and Docker Compose installed.
- A domain name, with DNS records pointing at the server.

## Getting started

Start with the Traefik README, then the service you want:

- [traefik/README.md](traefik/README.md)
- [n8n/README.md](n8n/README.md)

## A note on security

Services bind only to the internal Docker network, never to `0.0.0.0`, so the only things exposed to
the internet are Traefik's ports 80 and 443. Keep your `.env` files private (they hold real
passwords and keys) and make sure `acme.json` stays `chmod 600`.
