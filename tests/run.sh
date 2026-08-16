#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
image=${GATEWAY_IMAGE:-gateway:local}
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
    --config /tests/fixtures/valid-routes.yaml \
    --edge-output /tmp/gateway-tests/edge.Caddyfile \
    --origin-output /tmp/gateway-tests/backend.caddy
if ! grep -F 'reverse_proxy https://origin.example.com' "$tmp_dir/edge.Caddyfile" >/dev/null \
    || ! grep -F 'redir "https://your-domain.example{uri}" 302' "$tmp_dir/backend.caddy" >/dev/null \
    || ! grep -F 'rewrite * "/new{uri}"' "$tmp_dir/backend.caddy" >/dev/null \
    || ! grep -F 'meta http-equiv=\"refresh\"' "$tmp_dir/backend.caddy" >/dev/null; then
    printf 'not ok - rewrite, redirect, meta redirect, or Anubis bypass was not rendered\n' >&2
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

sh -n "$repo_dir/docker/gateway/entrypoint.sh"
pass "gateway entrypoint passes shell syntax check"

ACME_EMAIL=admin@example.com \
CF_API_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
ANUBIS_DIFFICULTY=4 \
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
