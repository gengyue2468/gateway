# Gateway

Anubis bot protection, Caddy TLS, Coraza WAF, and multi-domain routing in one
container.

## Production

The production Compose file pulls the public image
`ghcr.io/gengyue2468/gateway:latest`; it does not build locally.

```sh
cp .env.example .env
mkdir -p secrets
openssl rand -hex 32 > secrets/anubis_ed25519
chmod 0600 secrets/anubis_ed25519
# Set ACME_EMAIL and CF_API_TOKEN in .env.
docker compose up -d
```

Edit `config/routes.yaml` to add routes. Changes to routes, the backend Caddy
file, and WAF overrides are hot-reloaded. Update the image with:

```sh
docker compose pull
docker compose up -d
```

## Development

EOS can build the image locally when needed:

```sh
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

Tests stay outside the image and run from the repository with `tests/run.sh`.
