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
- `bypass_anubis: true` sends a path directly from edge Caddy to the declared upstream, bypassing Anubis **and edge Coraza/WAF**. A configured route rate limit still applies. It requires `hostname` and `path`; bypass routes never use the cache, and `cache: true` is rejected. `rewrite`, `load_balance`, and explicit `health` settings are preserved on this edge route. Set route-level `methods: [GET, HEAD]` for a WebSocket-style bypass so only those methods use the direct handler; other methods continue through edge WAF and Anubis.

Routes without `hostname` are intentional backend-only rules. They are evaluated
by the origin Caddy after Anubis for any request that reaches it, and cannot use
`bypass_anubis` because the edge site has no host to match. Keep at least one
hostname route when the configuration is meant to serve public edge traffic.

Route redirects remain in the backend Caddy configuration and therefore pass
through the normal edge WAF and Anubis path. The edge's native HTTP-to-HTTPS
redirect and WebSocket upgrades remain protocol responses; they are not HTML
redirects.

Proxy routes use active upstream health checks by default. Set
`health.active: false` when an upstream intentionally has no health endpoint;
the proxy will still forward requests without probing it. For compatibility,
an edge bypass route only adds active health checks when it has an explicit
`health` block; an omitted block does not introduce a new probe for existing
direct routes.


## Caching

Shared caching is an explicit opt-in: a normal proxy route must set
`cache: true` or use the route-level `cache` object. The checked-in production
`routes.yaml` is deny-all, and the example public homepage marks its intended
cache behavior explicitly. This keeps an unreviewed route from becoming a
shared cache by default. The object form supports `ttl`, `stale`,
`default_cache_control`, `max_cacheable_body_bytes`, and `exclude_paths`;
omitted values retain the safe defaults of `4h`, `0s`,
`public, max-age=14400`, and `1048576` bytes. For v1 compatibility, an object
with `enabled: false` may retain an explicit no-op `sort_query: false`; active
cache policy values remain invalid while caching is disabled.

Opted-in routes cache only GET and HEAD requests without `Cookie`,
`Authorization`, client `no-cache`/`no-store` directives, WebSocket upgrades,
or login/admin/API/health paths. The original request path is tested before any
route rewrite, including `/api`, `/api/`, their children, `/healthz`, and
`/healthz/`. The gateway never removes `Cookie`; application session cookies
remain isolated and any request carrying a cookie bypasses the shared cache.

`exclude_paths` is a non-empty, duplicate-free list of RE2 path regexps. The
JSON Schema rejects empty, whitespace-only, CR/LF-containing, quoted, and
backtick-containing entries, while the renderer performs the final Go RE2
compilation check; the schema does not attempt to fully validate Go RE2
syntax. Each entry is rendered as a uniquely named negated `path_regexp` inside
the cache handler's own request matcher, so a matching request remains
routable but can never enter that route's cache handler. Matching uses the
original path before any route rewrite. This is useful as defense in depth when
a same-host direct bypass such as `/tty` also has a cached backend catch-all. It
does not create a bypass, change route selection, or move a request around the
edge WAF/Anubis boundary.

The bundled cache-handler v0.16/Souin 1.7.7 honors response `private`,
`no-store`, and `Vary` (including separate keys for declared varying headers and
no storage for `Vary: *`). It does not independently reject `Set-Cookie`, so
the renderer adds a Caddy response matcher to opted-in reverse proxies: any
`Set-Cookie` response is sent with deferred `Cache-Control: no-store` before
cache-handler sees it. The cookie is still delivered to the client.

When an opted-in origin sends no cache directive, the route's
`default_cache_control` is used. Do not opt in a route whose response varies on
a request header that is not declared in `Vary` or otherwise represented in the
cache key. The cache key retains the complete query string by default. The
schema exposes `sort_query` for forward compatibility, but the pinned
cache-handler v0.16.0 does not implement that Caddy option; `sort_query: true`
is rejected by both schema and renderer rather than emitting an unsupported
directive. `disable_query` is never rendered, and cookies are never stripped.

The cache-handler emits `Cache-Status`. To measure one public GET without any
write request, run the local-only benchmark against an explicitly chosen
endpoint:

```sh
CACHE_BENCH_URL=https://public.example/ CACHE_BENCH_WARM_REQUESTS=5 \
  CACHE_BENCH_CONCURRENT_REQUESTS=8 scripts/cache-benchmark.sh
```

It adds a unique query parameter so the same URL can be observed through cold,
warm, and concurrent phases, then prints status code, TTFB, `Cache-Status`, and
hit rate for each phase. It refuses `/api` paths and only invokes `curl`'s
default GET method.

The offline suite validates generated Caddy configuration and renderer
ordering; the benchmark and the isolated backend-cache live check are the
places to verify actual upstream cache behavior. The live check starts only the
generated backend Caddy and a local origin, not edge Caddy or Anubis. Origin
access logs prove that two `/tty` requests both reach upstream while two
`/ttyfoo` client requests reach upstream once because the second response is a
cache hit. It also retains the Set-Cookie storage-safety check.

## Rate Limiting

Normal and bypass routes may declare a per-client `rate_limit`. On a normal
route, the renderer applies the limit after edge Coraza/WAF and before Anubis;
on a bypass route, it remains inside the direct edge handler. Normal rate-limit
routes require a hostname so the edge can match them. The default key is the
connecting client address, and an IPv6 prefix can be configured to prevent
address rotation from bypassing the limit. Set route-level `methods` to
restrict which HTTP methods match a route; set rate-limit `methods` to restrict
which methods consume the zone.
Leave `OPTIONS` out of API quotas when CORS preflight should not consume the
business request budget.

## Edge WAF

The normal edge Caddy path runs Coraza with the bundled OWASP CRS before Anubis.
Direct `bypass_anubis` handlers are deliberately ordered before that WAF and
proxy straight to their declared upstream, so they bypass both Anubis and edge
Coraza. This is retained for Komari/WebSocket-style routes and is an explicit
security boundary, not an accidental WAF omission. Response-body inspection is
disabled at the edge to avoid buffering and to preserve streaming behavior;
request inspection, CRS anomaly scoring, and the configured overrides remain
enabled for the normal path. Memos gRPC-Web receives only two narrowly scoped
protocol-rule exclusions for its protobuf endpoint prefix; the rest of CRS
remains active there.

Every edge proxy overwrites the canonical client context headers before
forwarding: `X-Real-IP`, `X-Client-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`,
`X-Forwarded-Host`, `X-Forwarded-Port`, `X-Forwarded-Uri`, and
`X-Forwarded-Method`. Caddy's default upstream Host/SNI pairing is preserved,
along with the original URI and HTTP version. For a bypass route with a rewrite,
Caddy saves `X-Original-URI` before the rewrite and forwards that saved value;
the rewritten URI cannot overwrite the original-URI contract. Umami can use the
client IP for its GeoIP lookup; the
gateway does not invent or trust spoofable `CF-IPCountry` headers because these
domains connect directly to the VPS rather than through Cloudflare proxying.

Backend Caddy trusts forwarded client-IP headers only when the direct peer is
loopback (`127.0.0.1/32` or `::1/128`), which is the Anubis proxy in the
container. It uses strict right-to-left parsing and does not trust private
network ranges. Direct routes do not use this backend trust configuration.

Anubis reads `ANUBIS_DIFFICULTY` from the deployment `.env` and passes it to
the daemon as its default difficulty. Ordinary requests still receive a
challenge at this base difficulty; successive risk tiers use base plus one,
plus two, and plus three, capped at 64. Extreme weight and explicit malicious
bot rules are denied. This keeps the environment setting authoritative while
preserving a graduated challenge pipeline.

The authorization cookie defaults to 24 hours. Set
`ANUBIS_COOKIE_EXPIRATION_TIME` to override the duration, for example `12h`.
The cookie name is intentionally not copied into cache rules because Anubis
does not treat it as a stable public API.

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

For `www.gengyue.dev`, non-GET/HEAD requests remain denied. GET/HEAD requests
for ordinary pages without a query string receive an Anubis challenge; query
requests and `/tty` (including descendants) also challenge. The `/tty(/.*)?`
GET/HEAD edge bypass remains in the route configuration, so its WebSocket path
is not changed by the ordinary-page policy. The three exact static-host rules
remain ALLOW rules, and the good-crawler import is evaluated after the www
page challenge.

For `gengyue.dev`, only queryless GET/HEAD requests are allowed so the apex
redirect fallback is not challenged. Requests with a query string and all
non-read methods remain in the challenge or deny pipeline.
