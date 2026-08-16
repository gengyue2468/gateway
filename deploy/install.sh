#!/bin/sh
set -eu

base_url=${GATEWAY_DEPLOY_URL:-https://raw.githubusercontent.com/gengyue2468/gateway/main/deploy}
schema_url=${GATEWAY_SCHEMA_URL:-https://raw.githubusercontent.com/gengyue2468/gateway/main/config/routes.schema.json}

mkdir -p config secrets

download_url() {
	source_url=$1
	target=$2
	if [ ! -e "$target" ]; then
		curl -fsSL "$source_url" -o "$target"
	fi
}

download() {
	source=$1
	target=$2
	download_url "$base_url/$source" "$target"
}

download docker-compose.yml docker-compose.yml
download config/routes.yaml config/routes.yaml
download_url "$schema_url" config/routes.schema.json
download .env.example .env.example

if [ ! -e .env ]; then
    cp .env.example .env
fi
chmod 0600 .env

if [ ! -e secrets/anubis_ed25519 ]; then
    openssl rand -hex 32 > secrets/anubis_ed25519
    chmod 0600 secrets/anubis_ed25519
fi

printf '%s\n' 'Deployment files are ready.'
