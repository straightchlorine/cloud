#!/usr/bin/env bash
# The compose argv of every cell, from lane.sh against the fake docker, equals golden/argv.txt.
#   bash tests/bench/test_golden.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

got=$(bash "$HERE/gen-golden.sh")
check "golden: argv of every cell" "$(diff <(echo "$got") "$HERE/golden/argv.txt" > /dev/null && echo same || echo differ)" "same"
check "golden: 195 cells" "$(echo "$got" | wc -l)" "195"

finish
