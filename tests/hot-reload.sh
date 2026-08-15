#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
container=${GATEWAY_CONTAINER:-gateway}
config_file=$repo_dir/config/routes.yaml
backup=$(mktemp)
attempts=30

restore() {
    if [ -f "$backup" ]; then
        cp "$backup" "$config_file"
        rm -f "$backup"
    fi
}
trap restore EXIT INT TERM

cp "$config_file" "$backup"

wait_for_route() {
    expected=$1
    count=0
    while [ "$count" -lt "$attempts" ]; do
        if docker exec "$container" grep -F "$expected" /run/gateway/backend.caddy >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    return 1
}

if ! docker inspect "$container" >/dev/null 2>&1; then
    printf 'live hot-reload test requires container %s\n' "$container" >&2
    exit 1
fi

initial_started=$(docker inspect "$container" --format '{{.State.StartedAt}}')
initial_pid=$(docker inspect "$container" --format '{{.State.Pid}}')

cp "$repo_dir/tests/fixtures/reload-a.yaml" "$config_file"
if ! wait_for_route 'https://origin-a.example.com'; then
    printf 'route A was not hot-reloaded\n' >&2
    exit 1
fi

cp "$repo_dir/tests/fixtures/invalid-no-catchall.yaml" "$config_file"
sleep 4
if ! docker exec "$container" grep -F 'https://origin-a.example.com' /run/gateway/backend.caddy >/dev/null 2>&1; then
    printf 'invalid configuration replaced the last good configuration\n' >&2
    exit 1
fi

cp "$repo_dir/tests/fixtures/reload-b.yaml" "$config_file"
if ! wait_for_route 'https://origin-b.example.com'; then
    printf 'route B was not hot-reloaded\n' >&2
    exit 1
fi

restore
if ! wait_for_route 'respond 444'; then
    printf 'original route configuration was not restored\n' >&2
    exit 1
fi
final_started=$(docker inspect "$container" --format '{{.State.StartedAt}}')
final_pid=$(docker inspect "$container" --format '{{.State.Pid}}')
if [ "$initial_started" != "$final_started" ] || [ "$initial_pid" != "$final_pid" ]; then
    printf 'container restarted during hot-reload test\n' >&2
    exit 1
fi
trap - EXIT INT TERM
rm -f "$backup"
printf 'ok - route configuration hot-reloaded without rebuilding or restarting\n'
