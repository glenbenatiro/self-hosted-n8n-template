notes before use

1. create an .env file for env vars found in docker-compose.yml, use .env.example as guide
2. change the email address in the traefik.yml file certificatesResolvers -> letsencrypt -> acme -> email to yours
3. touch acme.json && chmod 600 acme.json
