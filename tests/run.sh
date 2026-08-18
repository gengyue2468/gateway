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
	|| ! grep -F 'default_cache_control "public, max-age=14400"' "$tmp_dir/backend.caddy" >/dev/null \
    || ! grep -F 'max_cacheable_body_bytes 1048576' "$tmp_dir/backend.caddy" >/dev/null \
    || ! grep -F '                hide' "$tmp_dir/backend.caddy" >/dev/null \
    || ! grep -Fx '            health_uri /' "$tmp_dir/backend.caddy" >/dev/null \
    || ! grep -F 'header_up Host {http.request.host}' "$tmp_dir/edge.Caddyfile" >/dev/null \
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
    || ! grep -F 'meta http-equiv=\"refresh\"' "$tmp_dir/backend.caddy" >/dev/null; then
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
pass "rewrite, redirect, meta redirect, and Anubis bypass render"

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
expect_failure "redirect cannot include an upstream" \
    run_renderer --config /tests/fixtures/invalid-action-service.yaml --check
expect_failure "Anubis bypass requires a path" \
    run_renderer --config /tests/fixtures/invalid-bypass.yaml --check
expect_failure "rate limit requires an Anubis bypass" \
    run_renderer --config /tests/fixtures/invalid-rate-limit.yaml --check
expect_failure "rate limit methods must be uppercase HTTP methods" \
    run_renderer --config /tests/fixtures/invalid-rate-limit-method.yaml --check
expect_failure "route methods must be uppercase HTTP methods" \
    run_renderer --config /tests/fixtures/invalid-route-method.yaml --check
expect_failure "invalid ACME override is rejected" \
    docker run --rm \
        -e ACME_DNS_CHALLENGE_OVERRIDE_DOMAIN=not_a_dns_name \
        --entrypoint /usr/local/bin/route-renderer \
        -v "$repo_dir/tests/fixtures:/tests/fixtures:ro" \
        "$image" --config /tests/fixtures/empty-routes.yaml --check

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

printf '%s tests passed\n' "$passed"
