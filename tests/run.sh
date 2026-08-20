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
        -v "$repo_dir/config:/tests/config:ro" \
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
    "$repo_dir/config/routes.example.yaml" \
    "$repo_dir/tests/fixtures/valid-routes.yaml" \
    "$repo_dir/tests/fixtures/empty-routes.yaml" \
    "$repo_dir/tests/fixtures/path-only-backend.yaml" \
    "$repo_dir/tests/fixtures/cache-safety.yaml" \
    "$repo_dir/tests/fixtures/cache-policy.yaml" \
    "$repo_dir/tests/fixtures/valid-cache-disabled-defaults.yaml" \
    "$repo_dir/tests/fixtures/valid-bypass-options.yaml" \
    "$repo_dir/tests/fixtures/valid-allowed-remote-ips.yaml" \
    "$repo_dir/tests/fixtures/valid-normal-rate-limit.yaml" \
    "$repo_dir/tests/fixtures/live-cache.yaml"
pass "route fixtures pass JSON schema validation"

run_renderer --config /tests/fixtures/valid-routes.yaml --check
pass "valid routes pass validation"

run_renderer --config /tests/fixtures/empty-routes.yaml --check
pass "empty deny-all routes pass validation"

run_renderer --config /tests/config/routes.example.yaml --check
pass "example routes pass validation"

run_renderer \
    --config /tests/fixtures/valid-allowed-remote-ips.yaml \
    --edge-output /tmp/gateway-tests/allowed-remote-ips-edge.Caddyfile \
    --origin-output /tmp/gateway-tests/allowed-remote-ips-backend.caddy
awk '
    /^    @bypass0 \{/ { copy = 1 }
    copy { print }
    copy && /^    \}/ { exit }
' "$tmp_dir/allowed-remote-ips-edge.Caddyfile" >"$tmp_dir/allowed-remote-ips-matcher"
if ! grep -F 'host dns.gy.run' "$tmp_dir/allowed-remote-ips-matcher" >/dev/null \
    || ! grep -F 'path_regexp bypass0 "^/dns-query$"' "$tmp_dir/allowed-remote-ips-matcher" >/dev/null \
    || ! grep -F 'method GET POST' "$tmp_dir/allowed-remote-ips-matcher" >/dev/null \
    || ! grep -F 'remote_ip 100.64.0.0/10' "$tmp_dir/allowed-remote-ips-matcher" >/dev/null; then
    printf '%s\n' 'not ok - allowed remote IPs were not ANDed into the edge bypass matcher' >&2
    exit 1
fi
awk '
    /^    @route2 \{/ { copy = 1 }
    copy { print }
    copy && /^    \}/ { exit }
' "$tmp_dir/allowed-remote-ips-edge.Caddyfile" >"$tmp_dir/allowed-remote-ips-normal-matcher"
if ! grep -F 'host api.gy.run' "$tmp_dir/allowed-remote-ips-normal-matcher" >/dev/null \
    || ! grep -F 'path_regexp route2 "^/private$"' "$tmp_dir/allowed-remote-ips-normal-matcher" >/dev/null \
    || ! grep -F 'remote_ip 100.64.0.0/10' "$tmp_dir/allowed-remote-ips-normal-matcher" >/dev/null \
    || ! grep -F 'not remote_ip 100.64.0.0/10' "$tmp_dir/allowed-remote-ips-edge.Caddyfile" >/dev/null \
    || ! grep -F 'handle @route2 {' "$tmp_dir/allowed-remote-ips-edge.Caddyfile" >/dev/null; then
    printf '%s\n' 'not ok - allowed remote IPs did not constrain a normal edge route' >&2
    exit 1
fi
pass "allowed remote IPs render as an edge source-IP matcher"

run_renderer \
    --config /tests/fixtures/valid-cache-disabled-defaults.yaml \
    --edge-output /tmp/gateway-tests/cache-disabled-edge.Caddyfile \
    --origin-output /tmp/gateway-tests/cache-disabled-backend.caddy
if grep -F 'cache @cacheable0 {' "$tmp_dir/cache-disabled-backend.caddy" >/dev/null; then
    printf '%s\n' 'not ok - disabled cache with v1-compatible default fields rendered a cache handler' >&2
    exit 1
fi
pass "disabled cache accepts v1-compatible default fields"

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
if grep -F 'remote_ip ' "$tmp_dir/edge.Caddyfile" >/dev/null; then
	printf 'not ok - legacy routes unexpectedly rendered an IP matcher\n' >&2
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
    --config /tests/fixtures/live-cache.yaml \
    --edge-output /tmp/gateway-tests/cache-exclude-edge.Caddyfile \
    --origin-output /tmp/gateway-tests/cache-exclude-backend.caddy
awk '
    /^    @bypass0 \{/ { copy = 1 }
    copy { print }
    copy && /^    \}/ { exit }
' "$tmp_dir/cache-exclude-edge.Caddyfile" >"$tmp_dir/cache-exclude-bypass-matcher"
if ! grep -F 'method GET HEAD' "$tmp_dir/cache-exclude-bypass-matcher" >/dev/null; then
    printf '%s\n' 'not ok - same-host tty bypass lost its GET/HEAD method boundary' >&2
    exit 1
fi
if ! grep -F 'not path_regexp cache_exclude_1_0 "^/tty(/.*)?$"' "$tmp_dir/cache-exclude-backend.caddy" >/dev/null \
    || ! grep -F 'cache @cacheable1 {' "$tmp_dir/cache-exclude-backend.caddy" >/dev/null \
    || grep -F 'handle @route0 {' "$tmp_dir/cache-exclude-backend.caddy" >/dev/null; then
    printf 'not ok - same-host tty cache exclusion was not rendered on the backend cache handler\n' >&2
    exit 1
fi
if ! awk '
    /^    handle @bypass0 \{/ { bypass = NR }
    /^        coraza_waf \{/ { waf = NR }
    END { exit !(bypass > 0 && waf > 0 && bypass < waf) }
' "$tmp_dir/cache-exclude-edge.Caddyfile"; then
    printf 'not ok - same-host tty bypass was not placed before the edge WAF\n' >&2
    exit 1
fi
pass "same-host bypass and backend cache exclusion preserve the security boundary"

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
validate_caddy_configs valid-allowed-remote-ips.yaml
pass "allowed remote IPs pass real Caddy validation"
validate_caddy_configs valid-normal-rate-limit.yaml
pass "normal route rate limit passes real Caddy validation"
validate_caddy_configs live-cache.yaml
pass "same-host bypass and cache exclusion pass real Caddy validation"
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
expect_failure "cache policy scalar types are rejected" \
    run_renderer --config /tests/fixtures/invalid-cache-types.yaml --check
expect_failure "empty cache path exclusions are rejected" \
    run_renderer --config /tests/fixtures/invalid-cache-exclude-empty.yaml --check
expect_failure "empty cache path exclusion items are rejected" \
    run_renderer --config /tests/fixtures/invalid-cache-exclude-empty-item.yaml --check
expect_failure "whitespace-only cache path exclusion items are rejected" \
    run_renderer --config /tests/fixtures/invalid-cache-exclude-whitespace.yaml --check
expect_failure "invalid cache path exclusion regexps are rejected" \
    run_renderer --config /tests/fixtures/invalid-cache-exclude-regex.yaml --check
expect_failure "duplicate cache path exclusions are rejected" \
    run_renderer --config /tests/fixtures/invalid-cache-exclude-duplicate.yaml --check
expect_failure "cache path exclusions reject Caddy control characters" \
    run_renderer --config /tests/fixtures/invalid-cache-exclude-control.yaml --check
expect_failure "disabled cache objects reject policy fields" \
    run_renderer --config /tests/fixtures/invalid-cache-disabled-policy.yaml --check
expect_failure "redirect cannot include an upstream" \
    run_renderer --config /tests/fixtures/invalid-action-service.yaml --check
expect_failure "Anubis bypass requires a path" \
    run_renderer --config /tests/fixtures/invalid-bypass.yaml --check
expect_failure "edge Anubis bypass requires a hostname" \
    run_renderer --config /tests/fixtures/invalid-bypass-path-only.yaml --check
expect_failure "Anubis bypass cannot enable cache" \
    run_renderer --config /tests/fixtures/invalid-bypass-cache.yaml --check
expect_failure "invalid allowed remote CIDR is rejected" \
    run_renderer --config /tests/fixtures/invalid-allowed-remote-ips.yaml --check
expect_failure "empty allowed remote IP list is rejected" \
    run_renderer --config /tests/fixtures/invalid-allowed-remote-ips-empty.yaml --check
expect_failure "empty allowed remote IP item is rejected" \
    run_renderer --config /tests/fixtures/invalid-allowed-remote-ips-empty-item.yaml --check
expect_failure "duplicate allowed remote CIDR is rejected" \
    run_renderer --config /tests/fixtures/invalid-allowed-remote-ips-duplicate.yaml --check
expect_failure "backend-only allowed remote IP route is rejected" \
    run_renderer --config /tests/fixtures/invalid-allowed-remote-ips-backend-only.yaml --check
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
expect_failure "schema rejects invalid cache policy scalar types" \
    validate_schema "$repo_dir/tests/fixtures/invalid-cache-types.yaml"
expect_failure "schema rejects empty cache path exclusions" \
    validate_schema "$repo_dir/tests/fixtures/invalid-cache-exclude-empty.yaml"
expect_failure "schema rejects empty cache path exclusion items" \
    validate_schema "$repo_dir/tests/fixtures/invalid-cache-exclude-empty-item.yaml"
expect_failure "schema rejects whitespace-only cache path exclusion items" \
    validate_schema "$repo_dir/tests/fixtures/invalid-cache-exclude-whitespace.yaml"
expect_failure "schema rejects duplicate cache path exclusions" \
    validate_schema "$repo_dir/tests/fixtures/invalid-cache-exclude-duplicate.yaml"
expect_failure "schema rejects cache path exclusion control characters" \
    validate_schema "$repo_dir/tests/fixtures/invalid-cache-exclude-control.yaml"
expect_failure "schema rejects policy fields on disabled cache objects" \
    validate_schema "$repo_dir/tests/fixtures/invalid-cache-disabled-policy.yaml"
expect_failure "schema rejects an edge bypass without hostname" \
    validate_schema "$repo_dir/tests/fixtures/invalid-bypass-path-only.yaml"
expect_failure "schema rejects an invalid allowed remote CIDR" \
    validate_schema "$repo_dir/tests/fixtures/invalid-allowed-remote-ips.yaml"
expect_failure "schema rejects an empty allowed remote IP list" \
    validate_schema "$repo_dir/tests/fixtures/invalid-allowed-remote-ips-empty.yaml"
expect_failure "schema rejects an empty allowed remote IP item" \
    validate_schema "$repo_dir/tests/fixtures/invalid-allowed-remote-ips-empty-item.yaml"
expect_failure "schema rejects duplicate allowed remote CIDRs" \
    validate_schema "$repo_dir/tests/fixtures/invalid-allowed-remote-ips-duplicate.yaml"
expect_failure "schema rejects backend-only allowed remote IP routes" \
    validate_schema "$repo_dir/tests/fixtures/invalid-allowed-remote-ips-backend-only.yaml"
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


policy_file="$repo_dir/config/anubis/bot-policy.yaml"
if ! grep -A2 -F "name: umami-script" "$policy_file" | grep -F 'action: ALLOW' >/dev/null \
    || ! grep -A2 -F "name: komari-manifest" "$policy_file" | grep -F 'action: ALLOW' >/dev/null \
    || ! grep -A2 -F "name: komari-favicon" "$policy_file" | grep -F 'action: ALLOW' >/dev/null; then
    printf '%s\n' 'not ok - static host allow rules changed' >&2
    exit 1
fi
if ! grep -A2 -F "name: www-non-read" "$policy_file" | grep -F 'action: DENY' >/dev/null \
    || ! grep -A2 -F "name: www-tty-or-query" "$policy_file" | grep -F 'action: CHALLENGE' >/dev/null \
    || ! grep -A2 -F "name: www-public-read" "$policy_file" | grep -F 'action: CHALLENGE' >/dev/null; then
    printf '%s\n' 'not ok - www Anubis actions are incorrect' >&2
    exit 1
fi
if ! awk '
    /import: \(data\)\/meta\/ai-block-aggressive.yaml/ { deny = NR }
    /import: \(data\)\/crawlers\/_allow-good.yaml/ { crawlers = NR }
    /name: apex-redirect-read/ { rule = NR; apex++ }
    END { exit !(apex == 1 && rule > deny && crawlers > rule) }
' "$policy_file" \
    || ! grep -F 'expression: '\''host == "gengyue.dev" && (method == "GET" || method == "HEAD") && size(query) == 0'\''' "$policy_file" >/dev/null \
    || ! grep -A2 -F "name: apex-redirect-read" "$policy_file" | grep -F 'action: ALLOW' >/dev/null; then
    printf '%s\n' 'not ok - apex redirect read ALLOW rule is missing, imprecise, or misplaced' >&2
    exit 1
fi
if ! awk '
    /name: www-public-read/ { public = NR }
    /import: \(data\)\/crawlers\/_allow-good.yaml/ { crawlers = NR }
    END { exit !(public > 0 && crawlers > public) }
' "$policy_file"; then
    printf '%s\n' 'not ok - good-crawler import bypasses the www public challenge' >&2
    exit 1
fi
pass "www pages challenge while static allows and tty/query boundaries remain"
pass "apex redirect allows only queryless GET/HEAD requests before good crawlers"
printf "%s tests passed\n" "$passed"
