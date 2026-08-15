#!/bin/sh
set -eu

base_url=${GATEWAY_DEPLOY_URL:-https://raw.githubusercontent.com/gengyue2468/gateway/main/deploy}

mkdir -p config secrets

download() {
    source=$1
    target=$2
    if [ ! -e "$target" ]; then
        curl -fsSL "$base_url/$source" -o "$target"
    fi
}

download docker-compose.yml docker-compose.yml
download config/routes.yaml config/routes.yaml
download .env.example .env.example

if [ ! -e .env ]; then
    cp .env.example .env
fi

if [ ! -e secrets/anubis_ed25519 ]; then
    openssl rand -hex 32 > secrets/anubis_ed25519
    chmod 0600 secrets/anubis_ed25519
fi

printf '%s\n' 'Deployment files are ready.'
