#!/usr/bin/env bash
# Pull a gpu-qp host's per-run output back to this machine. The host side is
# `gpu-qp run`, which writes one directory per run under ~/gpu-qp/gen.
#
# Usage: ./scripts/gpu-qp/collect.sh [ansible-host-alias] [destination]
set -euo pipefail

HOST="${1:-gpu-station}"
DEST="${2:-$HOME/gpu-qp-results/$HOST}"

echo "== Collecting $HOST:~/gpu-qp/gen -> $DEST =="
mkdir -p "$DEST"
rsync -az --info=stats2 "$HOST:~/gpu-qp/gen/" "$DEST/"

count=0
echo
echo "-- runs --"
for run_dir in "$DEST"/*/; do
  [ -d "$run_dir" ] || continue
  count=$((count + 1))
  status="$(sed -n 's/.*"exit_status": *\(-\{0,1\}[0-9]*\).*/\1/p' "$run_dir/run.json" 2>/dev/null | head -1)"
  printf '  %-20s exit=%s\n' "$(basename "$run_dir")" "${status:-no run.json}"
done

if [ "$count" -eq 0 ]; then
  echo "no run directories under $DEST - has 'gpu-qp run' been used on $HOST?" >&2
  exit 1
fi

echo
echo "Collected $count run(s)."
