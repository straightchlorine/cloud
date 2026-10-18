#!/usr/bin/env bash
# gpu-qp-ship.sh [--build] [HOST|-]
#
# Workstation side of `gpu-qp sync`: packs the current checkout (base commit + every change in
# the working tree, untracked files included, binaries included) into one bundle and pipes it
# to `gpu-qp sync` on HOST (default: gpu). With `-` as HOST the bundle goes to stdout instead,
# for `ssh gpu 'gpu-qp sync' < bundle` or for keeping a copy next to a run's evidence.
#
# The base commit only has to exist on the workstation: the host's origin is this repository,
# so unpushed commits are reachable. Run from the repository root.
#
# --build   ask the host to rebuild the GPU image right after applying (gpu-qp build)
set -euo pipefail

build=""
host="gpu"
for arg in "$@"; do
  case "$arg" in
    --build) build="--build" ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) host="$arg" ;;
  esac
done

git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "gpu-qp-ship: not inside a git checkout" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)"

# Intent-to-add makes untracked files appear in `git diff HEAD`; undone on exit, whatever happens.
mapfile -t untracked < <(git ls-files --others --exclude-standard)
if [ "${#untracked[@]}" -gt 0 ]; then
  git add -N -- "${untracked[@]}"
  trap 'git reset -q -- "${untracked[@]}"' EXIT
fi

base=$(git rev-parse HEAD)
branch=$(git rev-parse --abbrev-ref HEAD)
diff=$(mktemp)
trap 'rm -f "$diff"; [ "${#untracked[@]}" -eq 0 ] || git reset -q -- "${untracked[@]}"' EXIT
git diff --binary HEAD >"$diff"
files=$(grep -c '^diff --git' "$diff" || true)
digest=$(sha256sum <"$diff" | cut -c1-12)

bundle() {
  echo "# gpu-qp-sync base=${base} branch=${branch} files=${files} sha256=${digest} host=$(hostname) at=$(date -u +%FT%TZ)"
  cat "$diff"
}

echo "gpu-qp-ship: ${branch}@${base:0:7} + ${files} changed file(s) (${digest})" >&2
# The remote command is a literal, so nothing expands on either side by accident.
if [ "$host" = "-" ]; then
  bundle
elif [ -n "$build" ]; then
  bundle | ssh "$host" 'gpu-qp sync --build'
else
  bundle | ssh "$host" 'gpu-qp sync'
fi
