#!/bin/sh
set -eu

runtime_dir=/run/gateway
static_config_dir=/usr/share/gateway/config
runtime_config_dir=${GATEWAY_RUNTIME_CONFIG_DIR:-/etc/gateway/runtime-config}
backend_config=${BACKEND_CONFIG:-$static_config_dir/caddy/Caddyfile}
edge_config=${CADDY_CONFIG:-$runtime_dir/edge.Caddyfile}
backend_admin=127.0.0.1:2020
edge_admin=127.0.0.1:2019
edge_data=/var/lib/gateway/edge-data
edge_config_data=/var/lib/gateway/edge-config
backend_cache=/var/lib/gateway/backend-cache
backend_config_data=/var/lib/gateway/backend-config
anubis_data=/data/anubis
anubis_key=${ED25519_PRIVATE_KEY_HEX_FILE:-${anubis_data}/ed25519.key}

mkdir -p "$runtime_dir" "$runtime_config_dir" "$edge_data" "$edge_config_data" \
    "$backend_cache" "$backend_config_data" "$anubis_data"

route_config_path() {
    if [ -r "$runtime_config_dir/routes.yaml" ]; then
        printf '%s\n' "$runtime_config_dir/routes.yaml"
    else
        printf '%s\n' "$static_config_dir/routes.yaml"
    fi
}

secret=/run/secrets/anubis_ed25519
if [ ! -r "$secret" ]; then
    echo "Anubis signing key is not readable" >&2
    exit 1
fi
cp "$secret" "$anubis_key"
chown anubis:anubis "$anubis_key"
chmod 0400 "$anubis_key"

secret=/run/secrets/cloudflare_api_token
if [ ! -r "$secret" ]; then
    echo "Cloudflare API token is not readable" >&2
    exit 1
fi
CF_API_TOKEN=$(cat "$secret")
if [ -z "$CF_API_TOKEN" ]; then
    echo "Cloudflare API token is empty" >&2
    exit 1
fi
export CF_API_TOKEN

render_and_validate() {
    /usr/local/bin/route-renderer \
        --config "$(route_config_path)" \
        --edge-output "$runtime_dir/edge.Caddyfile" \
        --origin-output "$runtime_dir/backend.caddy"

    caddy validate --config "$backend_config" --adapter caddyfile
    caddy validate --config "$edge_config" --adapter caddyfile
}

reload_configs() {
    if ! render_and_validate; then
        echo "gateway: configuration validation failed; keeping the current configuration" >&2
        return 1
    fi

    if ! caddy reload --address "$backend_admin" --config "$backend_config" --adapter caddyfile; then
        echo "gateway: backend Caddy reload failed" >&2
        return 1
    fi
    if ! caddy reload --address "$edge_admin" --config "$edge_config" --adapter caddyfile; then
        echo "gateway: edge Caddy reload failed" >&2
        return 1
    fi
    return 0
}

config_fingerprint() {
    sha256sum \
        "$(route_config_path)" \
        "$backend_config" \
        "$static_config_dir/caddy/waf/overrides.conf" 2>/dev/null || true
}

watch_configs() {
    previous=$(config_fingerprint)
    echo "gateway: watching route and Caddy configuration"
    while :; do
        sleep 2
        current=$(config_fingerprint)
        if [ "$current" = "$previous" ]; then
            continue
        fi

        echo "gateway: configuration change detected"
        if reload_configs; then
            echo "gateway: configuration reloaded"
        fi
        previous=$current
    done
}

render_and_validate

export BIND=${ANUBIS_BIND:-:8923}
export BIND_NETWORK=${ANUBIS_BIND_NETWORK:-tcp}
export DIFFICULTY=${ANUBIS_DIFFICULTY:-4}
export ED25519_PRIVATE_KEY_HEX_FILE="$anubis_key"
export METRICS_BIND=${ANUBIS_METRICS_BIND:-:9090}
export METRICS_BIND_NETWORK=${ANUBIS_METRICS_BIND_NETWORK:-tcp}
export POLICY_FNAME=${ANUBIS_POLICY_FNAME:-$static_config_dir/anubis/bot-policy.yaml}
export SERVE_ROBOTS_TXT=${SERVE_ROBOTS_TXT:-0}
export TARGET=${TARGET:-http://127.0.0.1:8080}

XDG_DATA_HOME="$backend_cache" \
XDG_CONFIG_HOME="$backend_config_data" \
caddy run --config "$backend_config" --adapter caddyfile &
backend_pid=$!

setpriv \
    --reuid=1000 \
    --regid=1000 \
    --init-groups \
    /usr/local/bin/anubis &
anubis_pid=$!

XDG_DATA_HOME="$edge_data" \
XDG_CONFIG_HOME="$edge_config_data" \
caddy run --config "$edge_config" --adapter caddyfile &
edge_pid=$!

terminate_children() {
    for pid in ${backend_pid:-} ${anubis_pid:-} ${edge_pid:-} ${watch_pid:-}; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in ${backend_pid:-} ${anubis_pid:-} ${edge_pid:-} ${watch_pid:-}; do
        wait "$pid" 2>/dev/null || true
    done
}

trap 'terminate_children; exit 0' INT TERM

watch_configs &
watch_pid=$!

while :; do
    for pid in "$backend_pid" "$anubis_pid" "$edge_pid" "$watch_pid"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            terminate_children
            exit 1
        fi
    done
    sleep 2
done
