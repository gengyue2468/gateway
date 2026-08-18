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

## Certificate Validation

The edge uses two redundant ACME issuers: Cloudflare DNS-01 first, followed by
Caddy's native HTTP-01/TLS-ALPN-01 challenges. The latter is a fallback only;
with geo-distributed DNS, DNS-01 is the reliable method.

If the hostname is delegated to another DNS provider, delegate its ACME
challenge to a Cloudflare-managed zone with one CNAME record. For example, if
`www.gengyue.dev` is an AliDNS child zone, create this record there:

```text
_acme-challenge.www.gengyue.dev. CNAME _acme-challenge.cdnno.de.
```

Then set `ACME_DNS_CHALLENGE_OVERRIDE_DOMAIN` in `.env` to the exact canonical
CNAME target. The target may be `_acme-challenge.cdnno.de` or a delegated zone
such as `cdnno.de`; Caddy does not prepend `_acme-challenge` automatically.
This does not affect the geo-distributed records and does not add ACME settings
to `routes.yaml`.

## Route Actions

Routes may use these actions in addition to `service`:

- `redirect: https://example.com{uri}` emits a normal HTTP 302; no status field is needed.
- `rewrite: /new{uri}` changes the request URI internally before proxying and requires `service`.
- `meta_redirect: https://example.com/` emits a browser-only 200 HTML meta refresh. Do not use it for HTTP-to-HTTPS or WebSocket traffic.
- `bypass_anubis: true` sends a path directly from edge Caddy to the declared upstream, bypassing Anubis but still passing through edge Coraza and any route rate limit. It requires `path` and `cache: false`.

The default Caddy HTTP-to-HTTPS redirect and WebSocket upgrades remain native protocol responses; they are not HTML redirects.

Proxy routes use active upstream health checks by default. Set
`health.active: false` when an upstream intentionally has no health endpoint;
the proxy will still forward requests without probing it.

## Caching

Normal proxy routes cache GET and HEAD responses by default. Requests with
cookies, authorization, or WebSocket upgrades, plus API, login, admin, and
health paths, bypass the cache. Explicit origin cache directives take
precedence; when the origin sends no cache directive, the gateway uses
`public, max-age=14400` with a four-hour storage TTL. Routes such as WebSocket
endpoints can set `cache: false` explicitly.

## Rate Limiting

Bypass routes may declare a per-client `rate_limit`. The renderer emits the
optional Caddy rate-limit handler only for those routes; normal routes cannot
use it accidentally. The default key is the connecting client address, and an
IPv6 prefix can be configured to prevent address rotation from bypassing the
limit. Set route-level `methods` to restrict which HTTP methods bypass Anubis;
set rate-limit `methods` to restrict which methods consume the zone. Leave
`OPTIONS` out of API quotas when CORS preflight should not consume the business
request budget.

## Edge WAF

The edge Caddy configuration runs Coraza with the bundled OWASP CRS before both
Anubis and direct upstream bypass routes. This keeps a solved Anubis challenge
from bypassing request inspection. Response-body inspection is disabled at the
edge to avoid buffering and to preserve streaming behavior; request inspection,
CRS anomaly scoring, and the configured overrides remain enabled. Memos
gRPC-Web receives only two narrowly scoped protocol-rule exclusions for its
protobuf endpoint prefix; the rest of CRS remains active there.

Anubis reads `ANUBIS_DIFFICULTY` from the deployment `.env` and passes it to
the daemon as its default difficulty. Ordinary requests still receive a
challenge at this base difficulty; successive risk tiers use base plus one,
plus two, and plus three, capped at 64. Extreme weight and explicit malicious
bot rules are denied. This keeps the environment setting authoritative while
preserving a graduated challenge pipeline.

The authorization cookie defaults to 24 hours. Set
`ANUBIS_COOKIE_EXPIRATION_TIME` to override the duration, for example `12h`.

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
