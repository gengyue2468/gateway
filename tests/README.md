# Tests

Build the local image on EOS, then run the offline checks:

```sh
docker compose -f docker-compose.yml -f docker-compose.dev.yml build
tests/run.sh
```

`tests/run.sh` validates the YAML fixtures with `scripts/validate-schema.py` and
validates generated edge and backend Caddyfiles, including
`valid-bypass-options.yaml`, `cache-safety.yaml`, and `cache-policy.yaml`, with
the image's Caddy 2.11.4. It also checks that unsupported `sort_query` and
unsafe cache TTL values fail closed. The host needs `jsonschema==4.19.2` and
`PyYAML==6.0.2` (source CI installs these pinned versions).

The cache checks cover generated matcher ordering, request exclusions, response
`Set-Cookie` protection, route-level policy rendering, and Caddy configuration
syntax. They do not assert live HTTP cache hits or upstream response behavior
in the offline suite.

Run the live hot-reload check only during a maintenance window:

```sh
RUN_LIVE=1 tests/run.sh
```

Run the isolated cache safety check when Docker and curl are available. It uses
temporary containers and verifies that a response carrying `Set-Cookie` plus a
surrogate cache directive is not served from the shared cache:

```sh
RUN_CACHE_LIVE=1 tests/run.sh
```

Run the read-only GET benchmark against a deliberately selected public endpoint
to observe cold, warm, and concurrent `Cache-Status`, status code, TTFB, and hit
rate values:

```sh
CACHE_BENCH_URL=https://public.example/ scripts/cache-benchmark.sh
```

For a local port-forward or host-mapped Caddy site, set `CACHE_BENCH_HOST` to
the public hostname while keeping `CACHE_BENCH_URL` on `127.0.0.1`. The
benchmark appends a unique query parameter, uses only curl's default GET
method, and refuses `/api` targets. It never sends a write request.

The policy checks assert that ordinary no-query GET/HEAD pages on
`www.gengyue.dev` challenge, while non-read methods remain denied, query and
`/tty` requests remain challenge rules, the three exact static-host ALLOW rules
are unchanged, and the good-crawler import cannot bypass the www challenge.
