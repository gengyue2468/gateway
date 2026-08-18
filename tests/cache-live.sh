#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
image=${GATEWAY_IMAGE:-gateway:local}
suffix=$$
network="gateway-cache-test-$suffix"
origin="gateway-cache-origin-$suffix"
proxy="gateway-cache-proxy-$suffix"
tmp_dir=$(mktemp -d)

cleanup() {
    docker rm -f "$proxy" "$origin" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

docker image inspect "$image" >/dev/null
docker network create "$network" >/dev/null

cat >"$tmp_dir/origin.Caddyfile" <<'EOF'
:8080 {
    header {
        Set-Cookie "origin_session=secret; Path=/"
        Surrogate-Control "public, max-age=600"
    }
    respond "origin"
}
EOF

docker run -d --name "$origin" --network "$network" --network-alias origin \
    -v "$tmp_dir/origin.Caddyfile:/tmp/origin.Caddyfile:ro" \
    --entrypoint /usr/bin/caddy "$image" \
    run --config /tmp/origin.Caddyfile --adapter caddyfile >/dev/null

docker run --rm \
    -e ACME_DNS_CHALLENGE_OVERRIDE_DOMAIN=_acme-challenge.cdnno.de \
    --entrypoint /usr/local/bin/route-renderer \
    -v "$repo_dir/tests/fixtures:/tests/fixtures:ro" \
    -v "$tmp_dir:/tmp/gateway-tests" \
    "$image" \
    --config /tests/fixtures/live-cache.yaml \
    --edge-output /tmp/gateway-tests/unused-edge.Caddyfile \
    --origin-output /tmp/gateway-tests/backend.caddy

docker run -d --name "$proxy" --network "$network" \
    -p 127.0.0.1:0:8080 \
    -v "$tmp_dir/backend.caddy:/run/gateway/backend.caddy:ro" \
    --entrypoint /usr/bin/caddy "$image" \
    run --config /usr/share/gateway/config/caddy/Caddyfile --adapter caddyfile >/dev/null

proxy_port=$(docker inspect "$proxy" --format '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}')
headers_first="$tmp_dir/headers-first"
headers_second="$tmp_dir/headers-second"
body="$tmp_dir/body"

attempt=0
while [ "$attempt" -lt 30 ]; do
    if curl -fsS -H 'Host: cache-live.example' "http://127.0.0.1:$proxy_port/" -o "$body"; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 1
done
if [ "$attempt" -ge 30 ]; then
    printf '%s\n' 'cache proxy did not become ready' >&2
    exit 1
fi

curl -fsS -D "$headers_first" -H 'Host: cache-live.example' \
    "http://127.0.0.1:$proxy_port/" -o "$body"
curl -fsS -D "$headers_second" -H 'Host: cache-live.example' \
    "http://127.0.0.1:$proxy_port/" -o "$body"

if ! grep -Eiq '^Set-Cookie: origin_session=' "$headers_first" \
    || ! grep -Eiq '^Set-Cookie: origin_session=' "$headers_second"; then
    printf '%s\n' 'Set-Cookie was not delivered on both cache bypass responses' >&2
    exit 1
fi
if ! grep -Eiq '^Surrogate-Control: no-store' "$headers_first" \
    || ! grep -Eiq '^Surrogate-Control: no-store' "$headers_second"; then
    printf '%s\n' 'Surrogate-Control was not overridden for Set-Cookie responses' >&2
    exit 1
fi
if grep -Eiq '^Cache-Status:.*\bhit\b' "$headers_second"; then
    printf '%s\n' 'Set-Cookie response was served from cache' >&2
    exit 1
fi

printf '%s\n' 'ok - Set-Cookie responses with surrogate cache directives are not cached'
