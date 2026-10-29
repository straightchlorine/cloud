#!/usr/bin/env bash
# fingerprint.sh (via `gpu-qp fingerprint`): a read-only digest of the benchmark environment. One
# line per section, "NAME HASH16", then "FINGERPRINT HASH16". Containers, images, volumes and
# networks of side stacks (project qpside-*) are left out, so a side stack that is up does not
# change it. Writes nothing, not even the checkout's .git/index. Compare two runs with diff.
# shellcheck disable=SC2329  # the sec_* functions are called as "sec_$name"
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$HERE/env.sh"
S=$GPU_QP_SOURCE B=$GPU_QP_BENCH_ROOT L=$HERE
SIDE='(^|/|:)qpside'
PROJECT='{{index .Config.Labels "com.docker.compose.project"}}'

sec_checkout() {
  local g=(git --no-optional-locks -C "$S")
  "${g[@]}" rev-parse HEAD
  "${g[@]}" rev-parse --abbrev-ref HEAD
  cat "$S/.git/gpu-qp-patch" 2> /dev/null || echo no-patch
  "${g[@]}" status --porcelain=v1 -uall | sha256sum
  "${g[@]}" diff-index -p --binary HEAD | sha256sum
  (cd "$S" && sha256sum .env compose/* data/*)
}

sec_images() {
  docker images --no-trunc --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep -v '<none>' | grep -Ev "$SIDE" | sort
}

sec_containers() {
  docker ps -aq --no-trunc | xargs -r docker inspect --format \
    "$PROJECT {{.Name}} {{.Image}} {{.State.Status}} {{.State.StartedAt}} {{index .Config.Labels \"com.docker.compose.config-hash\"}} {{.NetworkSettings.Ports}}" \
    | grep -v '^qpside-' | sort
}

sec_volumes() {
  docker volume ls -q | grep -v '^qpside-' | sort | xargs -r docker volume inspect --format '{{.Name}} {{.CreatedAt}}'
}

sec_networks() {
  docker network ls --no-trunc --format '{{.ID}} {{.Name}}' | awk '$2 !~ /^qpside-/' | sort -k2
}

sec_gpuqp() {
  sha256sum /usr/local/bin/gpu-qp
  find "$L" -maxdepth 1 -type f | sort | xargs sha256sum
}

sec_bench() {
  readlink "$B/current"
  cat "$B/.active" 2> /dev/null
  (cd "$B" && find . -mindepth 2 -maxdepth 3 -type f \( -name phases -o -name supervise.done -o -name state.tsv \
    -o -name stop.request -o -path './*/lib/*' \) -print0 | sort -z | xargs -0 -r sha256sum)
}

sec_host() {
  host_signature
}

[ $# -eq 0 ] || { echo "usage: gpu-qp fingerprint" >&2; exit 2; }
out=''
for name in checkout images containers volumes networks gpuqp bench host; do
  out+=$(printf '%-10s %s' "$name" "$("sec_$name" 2>&1 | sha256sum | cut -c1-16)")$'\n'
done
printf '%s' "$out"
echo "FINGERPRINT $(printf '%s' "$out" | sha256sum | cut -c1-16)"
