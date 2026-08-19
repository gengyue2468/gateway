#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
image=${GATEWAY_IMAGE:-gateway:local}
acme_override=${ACME_DNS_CHALLENGE_OVERRIDE_DOMAIN:-_acme-challenge.cdnno.de}
tmp_dir=$(mktemp -d)
passed=0

cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

pass() {
    passed=$((passed + 1))
    printf 'ok - %s\n' "$1"
}

expect_failure() {
    name=$1
    shift
    if "$@" >"$tmp_dir/failure.log" 2>&1; then
        printf 'not ok - %s\n' "$name" >&2
        cat "$tmp_dir/failure.log" >&2
        exit 1
    fi
    pass "$name"
}

run_renderer() {
    docker run --rm \
        -e "ACME_DNS_CHALLENGE_OVERRIDE_DOMAIN=$acme_override" \
        --entrypoint /usr/local/bin/route-renderer \
        -v "$repo_dir/tests/fixtures:/tests/fixtures:ro" \
        -v "$tmp_dir:/tmp/gateway-tests" \
        "$image" "$@"
}

docker image inspect "$image" >/dev/null
pass "gateway image is available"

policy_status=0
timeout 3s docker run --rm \
    --entrypoint /bin/sh \
    "$image" \
    -c 'sed -e "s/__ANUBIS_BASE_DIFFICULTY__/4/g" -e "s/__ANUBIS_MODERATE_DIFFICULTY__/5/g" -e "s/__ANUBIS_HIGH_RISK_DIFFICULTY__/6/g" -e "s/__ANUBIS_EXTREME_DIFFICULTY__/7/g" /usr/share/gateway/config/anubis/bot-policy.yaml > /tmp/anubis-policy.yaml && exec /usr/local/bin/anubis --policy-fname /tmp/anubis-policy.yaml --bind 127.0.0.1:0 --metrics-bind 127.0.0.1:0 --target http://127.0.0.1:9 --ed25519-private-key-hex 0000000000000000000000000000000000000000000000000000000000000000' \
    >"$tmp_dir/anubis-policy.log" 2>&1 || policy_status=$?
if [ "$policy_status" -ne 124 ]; then
    printf 'not ok - Anubis policy did not load successfully\n' >&2
    cat "$tmp_dir/anubis-policy.log" >&2
    exit 1
fi
pass "Anubis policy loads with CEL allow rules"
if grep -F 'common/keep-internet-working.yaml' "$repo_dir/config/anubis/bot-policy.yaml" >/dev/null; then
    printf 'not ok - broad favicon allow policy remains enabled\n' >&2
    exit 1
fi
pass "static policy does not add a broad favicon allow"

validate_schema() {
    python3 "$repo_dir/scripts/validate-schema.py" "$repo_dir/config/routes.schema.json" "$@"
}

validate_schema \
    "$repo_dir/tests/fixtures/valid-routes.yaml" \
    "$repo_dir/tests/fixtures/empty-routes.yaml" \
    "$repo_dir/tests/fixtures/path-only-backend.yaml" \
    "$repo_dir/tests/fixtures/cache-safety.yaml" \
    "$repo_dir/tests/fixtures/cache-policy.yaml" \
    "$repo_dir/tests/fixtures/valid-bypass-options.yaml" \
    "$repo_dir/tests/fixtures/valid-normal-rate-limit.yaml"
pass "route fixtures pass JSON schema validation"

run_renderer --config /tests/fixtures/valid-routes.yaml --check
pass "valid routes pass validation"

run_renderer --config /tests/fixtures/empty-routes.yaml --check
pass "empty deny-all routes pass validation"

run_renderer \
    --config /tests/fixtures/no-active-health.yaml \
    --edge-output /tmp/gateway-tests/no-active-health-edge.Caddyfile \
    --origin-output /tmp/gateway-tests/no-active-health-backend.caddy
if grep -F 'health_uri' "$tmp_dir/no-active-health-backend.caddy" >/dev/null \
    || grep -F 'lb_try_duration' "$tmp_dir/no-active-health-backend.caddy" >/dev/null; then
    printf 'not ok - active health checks were not disabled\n' >&2
    exit 1
fi
pass "active health checks can be disabled"

run_renderer \
    --config /tests/fixtures/valid-routes.yaml \
    --edge-output /tmp/gateway-tests/edge.Caddyfile \
    --origin-output /tmp/gateway-tests/backend.caddy
if ! grep -F 'reverse_proxy https://origin.example.com' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'order coraza_waf first' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'coraza_waf {' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'SecResponseBodyAccess Off' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'encode zstd gzip' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F '0rtt off' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'read_header 10s' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'issuer acme {' "$tmp_dir/edge.Caddyfile" >/dev/null \
	|| ! grep -F 'dns_challenge_override_domain "_acme-challenge.cdnno.de"' "$tmp_dir/edge.Caddyfile" >/dev/null \
	|| ! grep -F 'issuer acme' "$tmp_dir/edge.Caddyfile" >/dev/null \
	|| ! grep -F 'ttl 4h' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'stale 0s' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'mode strict' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'default_cache_control "public, max-age=14400"' "$tmp_dir/backend.caddy" >/dev/null \
    || ! grep -F 'max_cacheable_body_bytes 1048576' "$tmp_dir/backend.caddy" >/dev/null \
    || ! grep -F '                hide' "$tmp_dir/backend.caddy" >/dev/null \
    || ! grep -Fx '            health_uri /' "$tmp_dir/backend.caddy" >/dev/null \
    || ! grep -F 'header_up X-Forwarded-For {http.request.remote.host}' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'header_up X-Real-IP {http.request.remote.host}' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'header_up X-Client-IP {http.request.remote.host}' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'header_up X-Forwarded-Proto {http.request.scheme}' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'header_up X-Forwarded-Host {http.request.host}' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'header_up X-Forwarded-Port {http.request.port}' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'header_up X-Forwarded-Uri {http.request.uri}' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'header_up X-Forwarded-Method {http.request.method}' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'header_up X-Original-URI {http.request.uri}' "$tmp_dir/edge.Caddyfile" >/dev/null \
	|| ! grep -F 'rate_limit {' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'zone terminal_per_client {' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F -A3 'path_regexp bypass0' "$tmp_dir/edge.Caddyfile" | grep -F 'method GET' >/dev/null \
    || ! grep -F 'method GET' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'ipv6_prefix 64' "$tmp_dir/edge.Caddyfile" >/dev/null \
	|| ! grep -F 'redir "https://your-domain.example{uri}" 302' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'rewrite * "/new{uri}"' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'meta http-equiv=\"refresh\"' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'not header Cookie *' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'not header Authorization *' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'not header Cache-Control *no-cache*' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'not header Cache-Control *no-store*' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'not header Pragma *no-cache*' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'not path /api /api/* /login* /logout* /admin* /healthz /healthz/*' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'header Set-Cookie *' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'header >Cache-Control "no-store"' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'header >Souin-Cache-Control "no-store"' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'header >Surrogate-Control "no-store"' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'header >CDN-Cache-Control "no-store"' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'copy_response' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'http://:80 {' "$tmp_dir/edge.Caddyfile" >/dev/null \
	|| ! grep -F 'redir @known_host https://{host}{uri} 308' "$tmp_dir/edge.Caddyfile" >/dev/null \
	|| ! grep -F 'handle_errors {' "$tmp_dir/edge.Caddyfile" >/dev/null \
	|| ! grep -F 'handle_errors {' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'header Content-Type "text/html; charset=utf-8"' "$tmp_dir/edge.Caddyfile" >/dev/null \
	|| ! grep -F 'header Content-Type "text/html; charset=utf-8"' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'respond <<GATEWAY_ERROR_HTML' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F '{err.status_code}' "$tmp_dir/edge.Caddyfile" >/dev/null \
	|| ! grep -F '!!! An unexpected error {err.status_code} occurred !!!' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F 'font-family: monospace' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F '{err.message}' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F '{err.trace}' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F '{err.status_text}' "$tmp_dir/backend.caddy" >/dev/null \
	|| ! grep -F '{err.id}' "$tmp_dir/backend.caddy" >/dev/null; then
	printf 'not ok - edge WAF, rewrite, redirect, meta redirect, or Anubis bypass was not rendered\n' >&2
	exit 1
fi
if grep -F 'coraza_waf {' "$tmp_dir/backend.caddy" >/dev/null; then
	printf 'not ok - Coraza was still rendered into the backend\n' >&2
	exit 1
fi
if ! grep -F 'ctl:ruleRemoveById=920420' "$repo_dir/config/caddy/waf/overrides.conf" >/dev/null \
    || ! grep -F 'ctl:ruleRemoveById=921150' "$repo_dir/config/caddy/waf/overrides.conf" >/dev/null; then
    printf 'not ok - scoped Memos gRPC WAF overrides are missing\n' >&2
    exit 1
fi
if grep -F 'handle @route0' "$tmp_dir/backend.caddy" >/dev/null; then
	printf 'not ok - Anubis bypass route was rendered into the backend\n' >&2
	exit 1
fi
if ! awk '
    /^    handle @bypass0 \{/ { bypass = NR }
    /^    route \{/ { route = NR }
    END { exit !(bypass > 0 && route > 0 && bypass < route) }
' "$tmp_dir/edge.Caddyfile"; then
	printf 'not ok - Anubis bypass was not placed before the edge WAF\n' >&2
	exit 1
fi
if ! grep -F '# @bypass0 intentionally bypasses Anubis and edge Coraza' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'request_header X-Original-URI {http.request.uri}' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'header_up X-Original-URI {http.request.header.X-Original-URI}' "$tmp_dir/edge.Caddyfile" >/dev/null; then
	printf 'not ok - bypass WAF boundary was not documented in generated config\n' >&2
	exit 1
fi
if grep -E '(^|[[:space:]])(header_up|request_header)[[:space:]].*(-Cookie|Cookie)' "$tmp_dir/backend.caddy" >/dev/null; then
	printf 'not ok - cache configuration strips or rewrites cookies\n' >&2
	exit 1
fi
if grep -F 'redir "https://your-domain.example{uri}" 302' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || grep -F 'meta http-equiv="refresh"' "$tmp_dir/edge.Caddyfile" >/dev/null; then
	printf 'not ok - backend redirects moved ahead of Anubis\n' >&2
	exit 1
fi
pass "rewrite, redirect, meta redirect, and Anubis bypass render"

run_renderer \
    --config /tests/fixtures/valid-normal-rate-limit.yaml \
    --edge-output /tmp/gateway-tests/normal-rate-limit-edge.Caddyfile \
    --origin-output /tmp/gateway-tests/normal-rate-limit-backend.caddy
if ! grep -F '# @rate_limit0 applies after Coraza and before Anubis.' "$tmp_dir/normal-rate-limit-edge.Caddyfile" >/dev/null \
    || ! grep -F 'handle @rate_limit0 {' "$tmp_dir/normal-rate-limit-edge.Caddyfile" >/dev/null \
    || ! grep -F 'zone normal_per_client {' "$tmp_dir/normal-rate-limit-edge.Caddyfile" >/dev/null \
    || ! grep -F 'events 600' "$tmp_dir/normal-rate-limit-edge.Caddyfile" >/dev/null \
    || ! grep -F 'reverse_proxy 127.0.0.1:8923' "$tmp_dir/normal-rate-limit-edge.Caddyfile" >/dev/null; then
    printf 'not ok - normal route rate limit was not rendered at the Anubis boundary\n' >&2
    exit 1
fi
if ! awk '
    /^        coraza_waf \{/ { waf = NR }
    /^        handle @rate_limit0 \{/ { limit = NR }
    END { exit !(waf > 0 && limit > 0 && waf < limit) }
' "$tmp_dir/normal-rate-limit-edge.Caddyfile"; then
    printf 'not ok - normal route rate limit was placed before the edge WAF\n' >&2
    exit 1
fi
if grep -F 'bypass' "$tmp_dir/normal-rate-limit-edge.Caddyfile" >/dev/null; then
    printf 'not ok - normal route rate limit unexpectedly bypassed Anubis\n' >&2
    exit 1
fi
pass "normal route rate limits remain behind the edge WAF"

run_renderer \
    --config /tests/fixtures/cache-policy.yaml \
    --edge-output /tmp/gateway-tests/cache-policy-edge.Caddyfile \
    --origin-output /tmp/gateway-tests/cache-policy-backend.caddy
if ! grep -F 'ttl 30m' "$tmp_dir/cache-policy-backend.caddy" >/dev/null \
    || ! grep -F 'stale 45s' "$tmp_dir/cache-policy-backend.caddy" >/dev/null \
    || ! grep -F 'default_cache_control "public, max-age=60"' "$tmp_dir/cache-policy-backend.caddy" >/dev/null \
    || ! grep -F 'max_cacheable_body_bytes 65536' "$tmp_dir/cache-policy-backend.caddy" >/dev/null; then
    printf 'not ok - route-level cache policy was not rendered\n' >&2
    exit 1
fi
if grep -E '(^|[[:space:]])(sort_query|disable_query)([[:space:]]|$)' "$tmp_dir/cache-policy-backend.caddy" >/dev/null; then
    printf 'not ok - unsupported or unsafe query-key directive was rendered\n' >&2
    exit 1
fi
pass "route-level cache policy renders without query or cookie bypasses"

run_renderer \
    --config /tests/fixtures/valid-bypass-options.yaml \
    --edge-output /tmp/gateway-tests/bypass-options-edge.Caddyfile \
    --origin-output /tmp/gateway-tests/bypass-options-backend.caddy
if ! grep -F 'rewrite * "/internal{uri}"' "$tmp_dir/bypass-options-edge.Caddyfile" >/dev/null \
    || ! grep -F 'lb_policy round_robin' "$tmp_dir/bypass-options-edge.Caddyfile" >/dev/null \
    || ! grep -F 'health_uri /readyz' "$tmp_dir/bypass-options-edge.Caddyfile" >/dev/null \
    || ! grep -F 'health_interval 15s' "$tmp_dir/bypass-options-edge.Caddyfile" >/dev/null \
    || ! grep -F 'health_timeout 2s' "$tmp_dir/bypass-options-edge.Caddyfile" >/dev/null \
    || ! grep -F 'lb_try_duration 4s' "$tmp_dir/bypass-options-edge.Caddyfile" >/dev/null \
    || ! grep -F 'header_up X-Forwarded-For {http.request.remote.host}' "$tmp_dir/bypass-options-edge.Caddyfile" >/dev/null; then
    printf 'not ok - bypass rewrite, load balancing, health, or headers were dropped\n' >&2
    exit 1
fi
if grep -F 'rewrite * "/internal{uri}"' "$tmp_dir/bypass-options-backend.caddy" >/dev/null; then
    printf 'not ok - bypass route was rendered into the backend\n' >&2
    exit 1
fi
pass "bypass rewrite, load balancing, health, and original URI render"

run_renderer \
    --config /tests/fixtures/cache-safety.yaml \
    --edge-output /tmp/gateway-tests/cache-safety-edge.Caddyfile \
    --origin-output /tmp/gateway-tests/cache-safety-backend.caddy
cache_line=$(grep -n -F 'cache @cacheable0 {' "$tmp_dir/cache-safety-backend.caddy" | cut -d: -f1)
rewrite_line=$(grep -n -F 'rewrite * "/internal{uri}"' "$tmp_dir/cache-safety-backend.caddy" | cut -d: -f1)
if [ -z "$cache_line" ] || [ -z "$rewrite_line" ] || [ "$cache_line" -ge "$rewrite_line" ]; then
    printf 'not ok - cache matcher was evaluated after the rewrite\n' >&2
    exit 1
fi
pass "cache matching uses the original URI before rewrite"

run_renderer \
    --config /tests/fixtures/path-only-backend.yaml \
    --edge-output /tmp/gateway-tests/path-only-edge.Caddyfile \
    --origin-output /tmp/gateway-tests/path-only-backend.caddy
if grep -F 'backend-only.example' "$tmp_dir/path-only-edge.Caddyfile" >/dev/null \
    || ! grep -F 'path_regexp route0' "$tmp_dir/path-only-backend.caddy" >/dev/null; then
    printf 'not ok - path-only backend route boundary was not preserved\n' >&2
    exit 1
fi
pass "path-only routes remain explicit backend-only rules"

run_renderer \
    --config /tests/fixtures/empty-routes.yaml \
    --edge-output /tmp/gateway-tests/empty-edge.Caddyfile \
    --origin-output /tmp/gateway-tests/empty-backend.caddy
if grep -F 'your-domain.example' "$tmp_dir/empty-edge.Caddyfile" >/dev/null; then
    printf 'not ok - empty configuration generated a public site\n' >&2
    exit 1
fi
pass "empty configuration generates no public site"

validate_caddy_configs() {
    fixture=$1
    docker run --rm \
        -e ACME_EMAIL=admin@example.com \
        -e CF_API_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        -e "ACME_DNS_CHALLENGE_OVERRIDE_DOMAIN=$acme_override" \
        -v "$repo_dir/tests/fixtures:/tests/fixtures:ro" \
        --entrypoint /bin/sh "$image" -c "\
            /usr/local/bin/route-renderer \
                --config /tests/fixtures/$fixture \
                --edge-output /run/gateway/edge.Caddyfile \
                --origin-output /run/gateway/backend.caddy && \
            caddy validate --config /usr/share/gateway/config/caddy/Caddyfile --adapter caddyfile && \
            caddy validate --config /run/gateway/edge.Caddyfile --adapter caddyfile"
}

validate_caddy_configs valid-routes.yaml
pass "valid generated Caddy configurations validate"
validate_caddy_configs empty-routes.yaml
pass "empty generated Caddy configurations validate"
validate_caddy_configs no-active-health.yaml
pass "no-active-health generated Caddy configuration validates"
validate_caddy_configs valid-bypass-options.yaml
pass "valid bypass options pass real Caddy validation"
validate_caddy_configs valid-normal-rate-limit.yaml
pass "normal route rate limit passes real Caddy validation"
validate_caddy_configs cache-safety.yaml
pass "cache safety generated Caddy configuration validates"
validate_caddy_configs cache-policy.yaml
pass "route-level cache policy generated Caddy configuration validates"

if ! grep -F 'trusted_proxies static 127.0.0.1/32 ::1/128' "$repo_dir/config/caddy/Caddyfile" >/dev/null \
    || ! grep -F 'trusted_proxies_strict' "$repo_dir/config/caddy/Caddyfile" >/dev/null \
    || ! grep -F 'client_ip_headers X-Forwarded-For X-Real-IP X-Client-IP' "$repo_dir/config/caddy/Caddyfile" >/dev/null; then
    printf 'not ok - backend trusted proxy configuration is incomplete\n' >&2
    exit 1
fi
if grep -F 'private_ranges' "$repo_dir/config/caddy/Caddyfile" >/dev/null; then
    printf 'not ok - backend trusts private proxy ranges\n' >&2
    exit 1
fi
pass "backend trusts only strict loopback proxy headers"

expect_failure "missing catch-all is rejected" \
    run_renderer --config /tests/fixtures/invalid-no-catchall.yaml --check
expect_failure "duplicate route is rejected" \
    run_renderer --config /tests/fixtures/invalid-duplicate.yaml --check
expect_failure "mixed upstream schemes are rejected" \
    run_renderer --config /tests/fixtures/invalid-mixed-scheme.yaml --check
expect_failure "invalid health settings are rejected" \
    run_renderer --config /tests/fixtures/invalid-health.yaml --check
expect_failure "unknown YAML fields are rejected" \
    run_renderer --config /tests/fixtures/invalid-unknown-field.yaml --check
expect_failure "unknown cache policy fields are rejected" \
    run_renderer --config /tests/fixtures/invalid-cache-unknown-field.yaml --check
expect_failure "redirect cannot include an upstream" \
    run_renderer --config /tests/fixtures/invalid-action-service.yaml --check
expect_failure "Anubis bypass requires a path" \
    run_renderer --config /tests/fixtures/invalid-bypass.yaml --check
expect_failure "edge Anubis bypass requires a hostname" \
    run_renderer --config /tests/fixtures/invalid-bypass-path-only.yaml --check
expect_failure "Anubis bypass cannot enable cache" \
    run_renderer --config /tests/fixtures/invalid-bypass-cache.yaml --check
expect_failure "service route requires hostname or path" \
    run_renderer --config /tests/fixtures/invalid-pathless-service.yaml --check
expect_failure "load balancing requires multiple upstreams" \
    run_renderer --config /tests/fixtures/invalid-single-load-balance.yaml --check
expect_failure "mixed catch-all upstreams are rejected" \
    run_renderer --config /tests/fixtures/invalid-mixed-catchall.yaml --check
expect_failure "redirect cannot have a rate limit" \
    run_renderer --config /tests/fixtures/invalid-redirect-rate-limit.yaml --check
expect_failure "meta redirect cannot have a rate limit" \
    run_renderer --config /tests/fixtures/invalid-meta-rate-limit.yaml --check
expect_failure "catch-all cannot have route options" \
    run_renderer --config /tests/fixtures/invalid-catchall-option.yaml --check
expect_failure "path-only rate limit cannot be rendered at the edge" \
    run_renderer --config /tests/fixtures/invalid-rate-limit.yaml --check
expect_failure "rate limit methods must be uppercase HTTP methods" \
    run_renderer --config /tests/fixtures/invalid-rate-limit-method.yaml --check
expect_failure "route methods must be uppercase HTTP methods" \
    run_renderer --config /tests/fixtures/invalid-route-method.yaml --check
expect_failure "unsupported cache query sorting is rejected" \
    run_renderer --config /tests/fixtures/invalid-cache-sort-query.yaml --check
expect_failure "zero cache TTL is rejected" \
    run_renderer --config /tests/fixtures/invalid-cache-ttl.yaml --check
expect_failure "invalid ACME override is rejected" \
    docker run --rm \
        -e ACME_DNS_CHALLENGE_OVERRIDE_DOMAIN=not_a_dns_name \
        --entrypoint /usr/local/bin/route-renderer \
        -v "$repo_dir/tests/fixtures:/tests/fixtures:ro" \
        "$image" --config /tests/fixtures/empty-routes.yaml --check

expect_failure "schema rejects unknown fields" \
    validate_schema "$repo_dir/tests/fixtures/invalid-unknown-field.yaml"
expect_failure "schema rejects unknown cache policy fields" \
    validate_schema "$repo_dir/tests/fixtures/invalid-cache-unknown-field.yaml"
expect_failure "schema rejects an edge bypass without hostname" \
    validate_schema "$repo_dir/tests/fixtures/invalid-bypass-path-only.yaml"
expect_failure "schema rejects a service route without hostname or path" \
    validate_schema "$repo_dir/tests/fixtures/invalid-pathless-service.yaml"
expect_failure "schema rejects load balancing with one upstream" \
    validate_schema "$repo_dir/tests/fixtures/invalid-single-load-balance.yaml"
expect_failure "schema rejects mixed catch-all upstreams" \
    validate_schema "$repo_dir/tests/fixtures/invalid-mixed-catchall.yaml"
expect_failure "schema rejects redirect rate limits" \
    validate_schema "$repo_dir/tests/fixtures/invalid-redirect-rate-limit.yaml"
expect_failure "schema rejects meta redirect rate limits" \
    validate_schema "$repo_dir/tests/fixtures/invalid-meta-rate-limit.yaml"
expect_failure "schema rejects catch-all options" \
    validate_schema "$repo_dir/tests/fixtures/invalid-catchall-option.yaml"
expect_failure "schema rejects unsupported cache query sorting" \
    validate_schema "$repo_dir/tests/fixtures/invalid-cache-sort-query.yaml"
expect_failure "schema rejects a path-only rate limit" \
    validate_schema "$repo_dir/tests/fixtures/invalid-rate-limit.yaml"

docker run --rm \
    -e ACME_DNS_CHALLENGE_OVERRIDE_DOMAIN=cdnno.de \
    --entrypoint /usr/local/bin/route-renderer \
    -v "$repo_dir/tests/fixtures:/tests/fixtures:ro" \
    -v "$tmp_dir:/tmp/gateway-tests" \
    "$image" \
    --config /tests/fixtures/valid-routes.yaml \
    --edge-output /tmp/gateway-tests/root-override.Caddyfile \
    --origin-output /tmp/gateway-tests/root-override-backend.caddy
if ! grep -F 'dns_challenge_override_domain "cdnno.de"' "$tmp_dir/root-override.Caddyfile" >/dev/null; then
    printf 'not ok - root CNAME ACME override was not rendered\n' >&2
    exit 1
fi
pass "root CNAME ACME override renders"

sh -n "$repo_dir/docker/gateway/entrypoint.sh"
pass "gateway entrypoint passes shell syntax check"
sh -n "$repo_dir/scripts/cache-benchmark.sh"
pass "cache benchmark passes shell syntax check"

ACME_EMAIL=admin@example.com \
CF_API_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
ACME_DNS_CHALLENGE_OVERRIDE_DOMAIN=_acme-challenge.cdnno.de \
ANUBIS_DIFFICULTY=4 \
ANUBIS_COOKIE_EXPIRATION_TIME=24h \
docker compose --project-directory "$repo_dir" \
    -f "$repo_dir/docker-compose.yml" config --quiet
pass "production Compose configuration is valid"

if docker run --rm --entrypoint /bin/sh "$image" -c '[ ! -e /tests ]'; then
    pass "tests are not included in the image"
else
    printf 'not ok - tests are included in the image\n' >&2
    exit 1
fi

if git -C "$repo_dir" ls-files --error-unmatch toy-origin >/dev/null 2>&1 \
    || git -C "$repo_dir" ls-files --error-unmatch mock-origin >/dev/null 2>&1; then
    printf 'not ok - mock fixture is tracked\n' >&2
    exit 1
fi
pass "mock fixtures are not tracked"

if git -C "$repo_dir" grep -n -E 'eos\.gy\.run|porter-gateway|origin-caddy' -- . ':(exclude)tests/run.sh' >/dev/null 2>&1; then
    printf 'not ok - old production names remain in tracked files\n' >&2
    exit 1
fi
pass "old production names are absent from tracked files"

if [ "${RUN_LIVE:-0}" = 1 ]; then
    "$repo_dir/tests/hot-reload.sh"
    pass "live configuration hot reload"
fi

if [ "${RUN_CACHE_LIVE:-0}" = 1 ]; then
    "$repo_dir/tests/cache-live.sh"
    pass "live cache Set-Cookie safety"
fi

printf '%s tests passed\n' "$passed"
