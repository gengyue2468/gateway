# Gateway

Anubis bot protection, Caddy TLS, Coraza WAF, and multi-domain routing in one
amd64 container.

## Deploy Without Cloning

The public image is `ghcr.io/gengyue2468/gateway:latest`. A small deployment
bundle contains only Compose, routes, environment, and the Anubis secret:

```sh
mkdir gateway-deploy && cd gateway-deploy
curl -fsSL https://raw.githubusercontent.com/gengyue2468/gateway/main/deploy/install.sh -o install.sh
sh install.sh
# Set ACME_EMAIL and CF_API_TOKEN in .env.
# Edit config/routes.yaml.
docker compose up -d
```

Update the image with:

```sh
docker compose pull
docker compose up -d
```

Route changes are hot-reloaded without rebuilding or restarting the container.

## Route Actions

Routes may use these actions in addition to `service`:

- `redirect: https://example.com{uri}` emits a normal HTTP 302; no status field is needed.
- `rewrite: /new{uri}` changes the request URI internally before proxying and requires `service`.
- `meta_redirect: https://example.com/` emits a browser-only 200 HTML meta refresh. Do not use it for HTTP-to-HTTPS or WebSocket traffic.
- `bypass_anubis: true` sends a path directly from edge Caddy to backend Caddy while retaining the backend WAF. It requires `path` and `cache: false`.

The default Caddy HTTP-to-HTTPS redirect and WebSocket upgrades remain native protocol responses; they are not HTML redirects.

## Release From EOS

EOS is the amd64 release builder. Log in to GHCR, then run:

```sh
docker login ghcr.io
scripts/publish-image.sh
```

The script builds locally, runs the tests, and pushes `latest` plus a commit
tag. Other hosts never compile the image.

## Development

```sh
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

Tests stay outside the image and run from the repository with `tests/run.sh`.
