#!/bin/sh
# Argument 4 is the object path and argument 6 is the property.
awk -v k="$4 $6" '{ i = index($0, "|"); if (substr($0, 1, i - 1) == k) { print substr($0, i + 1); f = 1 } }
  END { exit !f }' /run/molecule-nm-replies || { echo "Failed to get property $6" >&2; exit 1; }
