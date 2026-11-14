#!/usr/bin/env bash
# Installs requirements.yml, retried: Galaxy is slow or flaky at times.
# usage: install-collections.sh [ansible-galaxy collection install args...]
set -u
cd "$(dirname "$0")/.." || exit 2
for attempt in 1 2 3; do
    ansible-galaxy collection install -r requirements.yml "$@" && exit 0
    echo "galaxy attempt $attempt/3 failed, retry in 15s"
    sleep 15
done
echo "galaxy install failed"
exit 1
