ARG GO_VERSION=1.26.3
ARG CADDY_VERSION=2.11.4
ARG XCADDY_VERSION=0.4.6
ARG ANUBIS_VERSION=1.27.0
ARG ANUBIS_SRC_SHA256=ff44e2b5ae30417689a1a97e79f88a89e7fc70450444407d9568e7fe66258091

FROM golang:${GO_VERSION}-bookworm AS build

ARG CADDY_VERSION
ARG XCADDY_VERSION
ARG ANUBIS_VERSION
ARG ANUBIS_SRC_SHA256

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gzip \
        make \
    && rm -rf /var/lib/apt/lists/* \
    && go install github.com/caddyserver/xcaddy/cmd/xcaddy@v${XCADDY_VERSION}

WORKDIR /build/caddy

RUN /go/bin/xcaddy build v${CADDY_VERSION} \
    --with github.com/caddy-dns/cloudflare@v0.2.4 \
    --with github.com/corazawaf/coraza-caddy/v2@v2.5.0 \
    --with github.com/caddyserver/cache-handler@v0.16.0 \
    --with github.com/darkweak/storages/otter/caddy@v0.0.15 \
    --with github.com/mholt/caddy-ratelimit@5625512f24f6f59d6f64fb3aafe5eecff0b286db

COPY cmd/route-renderer/go.mod cmd/route-renderer/go.sum /build/renderer/
RUN cd /build/renderer && go mod download
COPY cmd/route-renderer/main.go /build/renderer/
RUN cd /build/renderer \
    && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o route-renderer .

WORKDIR /build/anubis

RUN curl -fsSL \
        "https://github.com/TecharoHQ/anubis/releases/download/v${ANUBIS_VERSION}/anubis-src-vendor-npm-${ANUBIS_VERSION}.tar.gz" \
        -o /tmp/anubis.tar.gz \
    && printf '%s  %s\n' "${ANUBIS_SRC_SHA256}" /tmp/anubis.tar.gz | sha256sum -c - \
    && tar --strip-components=1 -xzf /tmp/anubis.tar.gz -C /build/anubis \
    && rm /tmp/anubis.tar.gz \
    && make prebaked-build

FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 1000 anubis \
    && useradd --system --uid 1000 --gid anubis --home-dir /nonexistent --shell /usr/sbin/nologin anubis \
    && mkdir -p \
        /data/anubis \
        /usr/share/gateway/config \
        /run/gateway \
        /var/lib/gateway/edge-data \
        /var/lib/gateway/edge-config \
        /var/lib/gateway/backend-cache \
        /var/lib/gateway/backend-config \
    && chown -R anubis:anubis /data/anubis

COPY --from=build /build/caddy/caddy /usr/bin/caddy
COPY --from=build /build/renderer/route-renderer /usr/local/bin/route-renderer
COPY --from=build /build/anubis/var/anubis /usr/local/bin/anubis
COPY --from=build /build/anubis/var/robots2policy /usr/local/bin/robots2policy

COPY config /usr/share/gateway/config
COPY docker/gateway/entrypoint.sh /usr/local/bin/gateway-entrypoint

RUN chmod 0755 \
        /usr/local/bin/gateway-entrypoint \
        /usr/local/bin/route-renderer \
        /usr/local/bin/anubis \
        /usr/local/bin/robots2policy

ENTRYPOINT ["/usr/local/bin/gateway-entrypoint"]
