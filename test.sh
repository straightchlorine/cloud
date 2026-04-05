#!/bin/bash

set -e

for role in roles/common roles/backup-system roles/firewall roles/dns roles/automation roles/backup roles/monitoring roles/music-stack roles/prometheus-exporters; do
  echo "========================================="
  echo "Testing: $role"
  echo "========================================="
  cd "$role"
  uv run molecule test
  cd - > /dev/null
  echo "✅ PASSED: $role"
  echo ""
done

echo "========================================="
echo "✅ ALL TESTS PASSED"
echo "========================================="
