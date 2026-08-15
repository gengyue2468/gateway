#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repository=${GATEWAY_IMAGE_REPOSITORY:-ghcr.io/gengyue2468/gateway}
tag=${GATEWAY_IMAGE_TAG:-latest}
platform=${GATEWAY_PLATFORM:-linux/amd64}

if [ "$platform" != "linux/amd64" ]; then
    printf 'only linux/amd64 is supported by this release script\n' >&2
    exit 1
fi

architecture=$(docker info --format '{{.Architecture}}')
if [ "$architecture" != "amd64" ] && [ "$architecture" != "x86_64" ]; then
    printf 'this builder is %s; an amd64 EOS builder is required\n' "$architecture" >&2
    exit 1
fi

if ! git -C "$repo_dir" diff --quiet || ! git -C "$repo_dir" diff --cached --quiet; then
    printf 'working tree must be clean before publishing\n' >&2
    exit 1
fi

commit=$(git -C "$repo_dir" rev-parse --short HEAD)
image="$repository:$tag"
sha_image="$repository:sha-$commit"

cd "$repo_dir"
docker buildx build \
    --platform "$platform" \
    --file docker/gateway/Dockerfile \
    --tag "$image" \
    --tag "$sha_image" \
    --load \
    .

GATEWAY_IMAGE="$image" ./tests/run.sh

docker push "$image"
docker push "$sha_image"
printf 'published %s and %s\n' "$image" "$sha_image"
