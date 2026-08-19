#!/bin/sh
set -eu

die() {
    printf 'cache-benchmark: %s\n' "$1" >&2
    exit 2
}

url=${CACHE_BENCH_URL:-}
[ -n "$url" ] || die 'CACHE_BENCH_URL must be an explicit http:// or https:// public GET URL'
case "$url" in
    http://*|https://*) ;;
    *) die 'CACHE_BENCH_URL must use http:// or https://' ;;
esac
case "$url" in
    *'#'*) die 'CACHE_BENCH_URL must not contain a URL fragment' ;;
esac
host_header=${CACHE_BENCH_HOST:-}
if [ -n "$host_header" ]; then
    case "$host_header" in
        *[!A-Za-z0-9._:-]*) die 'CACHE_BENCH_HOST contains unsupported characters' ;;
    esac
fi

url_without_query=${url%%\?*}
case "$url_without_query" in
    */api|*/api/*) die 'refusing an /api benchmark target; choose a public non-API GET' ;;
esac

warm_requests=${CACHE_BENCH_WARM_REQUESTS:-5}
concurrent_requests=${CACHE_BENCH_CONCURRENT_REQUESTS:-8}
timeout_seconds=${CACHE_BENCH_TIMEOUT_SECONDS:-15}

positive_integer() {
    value=$1
    name=$2
    case "$value" in
        ''|*[!0-9]*|0) die "$name must be a positive integer" ;;
    esac
}

positive_integer "$warm_requests" CACHE_BENCH_WARM_REQUESTS
positive_integer "$concurrent_requests" CACHE_BENCH_CONCURRENT_REQUESTS
positive_integer "$timeout_seconds" CACHE_BENCH_TIMEOUT_SECONDS

case "$url" in
    *\?*) separator='&' ;;
    *) separator='?' ;;
esac
nonce=${CACHE_BENCH_NONCE:-"$(date +%s)-$$"}
target_url="${url}${separator}__gateway_cache_bench=${nonce}"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

curl_get() {
    headers=$1
    timing=$2
    error=$3
    if [ -n "$host_header" ]; then
        curl -sS \
            --connect-timeout "$timeout_seconds" \
            --max-time "$timeout_seconds" \
            -H "Host: $host_header" \
            -D "$headers" \
            -o /dev/null \
            -w '%{http_code}\t%{time_starttransfer}\n' \
            "$target_url" >"$timing" 2>"$error"
    else
        curl -sS \
            --connect-timeout "$timeout_seconds" \
            --max-time "$timeout_seconds" \
            -D "$headers" \
            -o /dev/null \
            -w '%{http_code}\t%{time_starttransfer}\n' \
            "$target_url" >"$timing" 2>"$error"
    fi
}

request() {
    phase=$1
    id=$2
    headers="$tmp_dir/${phase}-${id}.headers"
    timing="$tmp_dir/${phase}-${id}.timing"
    summary="$tmp_dir/${phase}-${id}.summary"

    curl_get "$headers" "$timing" "$tmp_dir/${phase}-${id}.error" || true

    status=000
    seconds=0
    if [ -s "$timing" ]; then
        IFS="$(printf '\t')" read -r status seconds <"$timing" || true
    fi
    [ -n "$status" ] || status=000
    [ -n "$seconds" ] || seconds=0
    cache_status=$(awk '
        tolower($1) == "cache-status:" {
            sub(/^[^:]*:[[:space:]]*/, "")
            print
            exit
        }
    ' "$headers" 2>/dev/null || true)
    [ -n "$cache_status" ] || cache_status=missing
    ttfb_ms=$(awk -v seconds="$seconds" 'BEGIN {
        if (seconds ~ /^[0-9]+(\.[0-9]+)?$/) {
            printf "%.1f", seconds * 1000
        } else {
            printf "na"
        }
    }')
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$phase" "$id" "$status" "$ttfb_ms" "$cache_status" >"$summary"
}

report_phase() {
    phase=$1
    count=$2
    hits=0
    i=1
    while [ "$i" -le "$count" ]; do
        summary="$tmp_dir/${phase}-${i}.summary"
        if [ -f "$summary" ]; then
            IFS="$(printf '\t')" read -r result_phase result_id status ttfb_ms cache_status <"$summary" || true
            printf 'phase=%s id=%s status=%s ttfb_ms=%s cache_status=%s\n' \
                "$result_phase" "$result_id" "$status" "$ttfb_ms" "$cache_status"
            case "$cache_status" in
                *hit*|*HIT*) hits=$((hits + 1)) ;;
            esac
        fi
        i=$((i + 1))
    done
    hit_rate=$(awk -v hits="$hits" -v count="$count" 'BEGIN {
        if (count > 0) printf "%.1f", (hits * 100) / count
        else printf "0.0"
    }')
    printf 'phase=%s summary requests=%s hits=%s hit_rate=%s%%\n' \
        "$phase" "$count" "$hits" "$hit_rate"
}

printf 'url=%s\n' "$target_url"
if [ -n "$host_header" ]; then
    printf 'host_header=%s\n' "$host_header"
fi
printf '%s\n' 'method=GET only; no write request is issued'

request cold 1
report_phase cold 1

i=1
while [ "$i" -le "$warm_requests" ]; do
    request warm "$i"
    i=$((i + 1))
done
report_phase warm "$warm_requests"

pids=''
i=1
while [ "$i" -le "$concurrent_requests" ]; do
    request concurrent "$i" &
    pids="$pids $!"
    i=$((i + 1))
done
for pid in $pids; do
    wait "$pid" || true
done
report_phase concurrent "$concurrent_requests"
