#!/bin/sh
# Keeps the newest KEEP semver tags of each honeywatch image repo and removes
# the older ones, then drops dangling layers.
#
# Invoked by honeywatch-image-prune.timer as: honeywatch-image-prune KEEP REPO...

set -eu

if [ "$#" -lt 2 ]; then
    echo "honeywatch-image-prune: usage: honeywatch-image-prune KEEP REPO..." >&2
    exit 1
fi
keep=$1
shift

# Fail here, not mid-loop, when the daemon is unreachable: otherwise every
# listing below would look like "no images" and the unit would report success.
docker version --format '{{.Server.Version}}' >/dev/null

for repo in "$@"; do
    tags=$(docker image ls "$repo" --format '{{.Tag}}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -rV | tail -n +"$((keep + 1))") || true
    for tag in $tags; do
        # No -f: docker refuses an image any container, running or stopped,
        # still references. That refusal is the in-use guard, not a failure.
        if out=$(docker rmi "${repo}:${tag}" 2>&1); then
            echo "honeywatch-image-prune: removed ${repo}:${tag}"
        else
            echo "honeywatch-image-prune: kept ${repo}:${tag} (in use): ${out}"
        fi
    done
done

# Dangling only (no -a): other images on the host are not ours to remove.
docker image prune -f
