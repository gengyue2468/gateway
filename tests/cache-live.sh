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
    log {
        output file /tmp/gateway-tests/origin-access.json
        format json
    }
    @root path /
    handle @root {
        header {
            Set-Cookie "origin_session=secret; Path=/"
            Surrogate-Control "public, max-age=600"
        }
        respond "origin"
    }
    handle {
        header Cache-Control "public, max-age=600"
        respond "origin"
    }
}
EOF

docker run -d --name "$origin" --network "$network" --network-alias origin \
    -v "$tmp_dir:/tmp/gateway-tests" \
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
headers_tty_first="$tmp_dir/headers-tty-first"
headers_tty_second="$tmp_dir/headers-tty-second"
headers_ttyfoo_first="$tmp_dir/headers-ttyfoo-first"
headers_ttyfoo_second="$tmp_dir/headers-ttyfoo-second"
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

curl -fsS -D "$headers_tty_first" -H 'Host: cache-live.example' \
    "http://127.0.0.1:$proxy_port/tty" -o "$body"
curl -fsS -D "$headers_tty_second" -H 'Host: cache-live.example' \
    "http://127.0.0.1:$proxy_port/tty" -o "$body"
if grep -Eiq '^Cache-Status:.*\bhit\b' "$headers_tty_first" \
    || grep -Eiq '^Cache-Status:.*\bhit\b' "$headers_tty_second"; then
    printf '%s\n' 'excluded /tty response was served from cache' >&2
    exit 1
fi

curl -fsS -D "$headers_ttyfoo_first" -H 'Host: cache-live.example' \
    "http://127.0.0.1:$proxy_port/ttyfoo" -o "$body"
curl -fsS -D "$headers_ttyfoo_second" -H 'Host: cache-live.example' \
    "http://127.0.0.1:$proxy_port/ttyfoo" -o "$body"
if ! grep -Eiq '^Cache-Status:.*\bhit\b' "$headers_ttyfoo_second"; then
    printf '%s\n' 'non-excluded /ttyfoo response did not hit the cache' >&2
    exit 1
fi

tty_requests=$(grep -c '"uri":"/tty"' "$tmp_dir/origin-access.json" || true)
ttyfoo_requests=$(grep -c '"uri":"/ttyfoo"' "$tmp_dir/origin-access.json" || true)
if [ "$tty_requests" -ne 2 ] || [ "$ttyfoo_requests" -ne 1 ]; then
    printf '%s\n' "unexpected upstream request counts: /tty=$tty_requests /ttyfoo=$ttyfoo_requests" >&2
    exit 1
fi
printf '%s\n' 'ok - Set-Cookie and excluded /tty responses are not cached; /ttyfoo is cached once upstream'
