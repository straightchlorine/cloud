#!/usr/bin/env bash
# fingerprint, the preflight `side` row and `side check` against the fake docker.
#   bash tests/bench/test_side.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
setup_tree

B=$T/bench
unset FAKE_MODE FAKE_RELEASE FAKE_PS FAKE_INFO FAKE_STACK FAKE_FAIL_CELL FAKE_SIDE FAKE_CONFIG
refused() { local err rc; err=$("$@" 2>&1 > /dev/null); rc=$?; echo "rc=$rc ${err//$'\n'/ }"; }
tree_sum() { (cd "$T" && find . -type f ! -name fake.log -print0 | sort -z | xargs -0 sha256sum | sha256sum); }
index_id() { echo "$(sha256sum < "$T/src/.git/index") $(stat -c %Y.%y "$T/src/.git/index")"; }

# 1. fingerprint: stable, read-only, blind to side stacks, sensitive to the bench. The checkout is
# a real git repo, with a tracked file touched so that a plain `git status` would rewrite the index.
git -C "$T/src" init -q
echo compose > "$T/src/compose/docker-compose.ml.yaml"
git -C "$T/src" add -A
git -C "$T/src" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m init
touch -d '2001-01-01' "$T/src/compose/docker-compose.ml.yaml"
export FAKE_IMAGES=$'quantum-pipeline:cpu sha256:aaa\nquantum-pipeline:gpu sha256:bbb'
export FAKE_IDS=abc
export FAKE_INSPECT='ml /ml-kafka sha256:kkk running 2026-10-01T00:00:00Z h1 map[9092/tcp:[{0.0.0.0 9092}]]'
export FAKE_VOLUMES=quantum-ml-data
export FAKE_NETWORKS='n1 quantum-ml-network'
idx=$(index_id)
cli fingerprint > "$T/fp1"
check "fingerprint: leaves .git/index untouched" "$(index_id)" "$idx"
git -C "$T/src" status --short > /dev/null
check "fingerprint: (a plain git status does rewrite it)" "$([ "$(index_id)" != "$idx" ] && echo yes || echo no)" "yes"
touch -d '2001-01-02' "$T/src/compose/docker-compose.ml.yaml"
before=$(tree_sum)
fp2=$(cli fingerprint)
check "fingerprint: stable" "$([ "$fp2" = "$(cat "$T/fp1")" ] && echo same || echo differ)" "same"
check "fingerprint: sections" "$(awk '{printf "%s ", $1}' "$T/fp1")" "checkout images containers volumes networks gpuqp bench host FINGERPRINT "
check "fingerprint: 16 hex per line" "$(grep -cE '^[a-zA-Z]+ +[0-9a-f]{16}$' "$T/fp1")" "9"
check "fingerprint: writes nothing" "$(tree_sum)" "$before"
check "fingerprint: no arguments" "$(refused cli fingerprint --against x | cut -c1-4)" "rc=2"
changed() { diff "$T/fp1" <(cli fingerprint) | grep '^>' | awk '{print $2}' | paste -sd' ' -; }

export FAKE_IMAGES=$'quantum-pipeline:cpu sha256:aaa\nquantum-pipeline:gpu sha256:ccc'
check "diff: image id changed" "$(changed)" "images FINGERPRINT"
export FAKE_IMAGES=$'quantum-pipeline:cpu sha256:aaa\nquantum-pipeline:gpu sha256:bbb'
export FAKE_INSPECT='ml /ml-kafka sha256:kkk running 2026-10-01T00:00:00Z h1 map[9093/tcp:[{0.0.0.0 9093}]]'
check "diff: published port changed" "$(changed)" "containers FINGERPRINT"
export FAKE_INSPECT='ml /ml-kafka sha256:kkk running 2026-10-01T00:00:00Z h1 map[9092/tcp:[{0.0.0.0 9092}]]'

# a side stack changes nothing
export FAKE_IMAGES+=$'\nqpside-x-web:latest sha256:sss\nregistry/qpside-y:1 sha256:ttt\nnginx:qpside-3 sha256:uuu'
export FAKE_IDS=$'abc\ndef'
export FAKE_INSPECT+=$'\nqpside-x /qpside-x-web-1 sha256:sss running 2026-10-02T00:00:00Z h2 map[8080/tcp:[{0.0.0.0 18080}]]'
export FAKE_VOLUMES+=$'\nqpside-x_data'
export FAKE_NETWORKS+=$'\nn2 qpside-x_default'
check "fingerprint: side stack is invisible" "$(changed)" ""
mkdir -p "$B/t/lib"
: > "$B/t/lib/override.yml"
check "fingerprint: a run's lib shows in bench" "$(changed)" "bench FINGERPRINT"

# 2. the preflight side row
pre() { cli start --check; }
check "side row: none" "$(pre | grep -c '^ok.side.none')" "1"
check "side row: running side stack" "$(FAKE_SIDE=$'ml\nqpside-x\nqpside-x' pre | grep '^FAIL.side.')" $'FAIL\tside\tside stack running: qpside-x'
check "side row: rc" "$(FAKE_SIDE=qpside-x pre > /dev/null; echo $?)" "1"
check "side row: start refuses" "$(FAKE_SIDE=qpside-x refused cli start --run s1 S | cut -c1-4)" "rc=1"
check "side row: start creates nothing" "$([ -e "$B/s1" ] && echo yes || echo no)" "no"

# 3. side check
D=$T/side-test
mkdir -p "$D/compose" "$D/data"
: > "$D/.env"
: > "$D/compose/docker-compose.ml.yaml"
export FAKE_VOLUMES=ml_airflow
export FAKE_NETWORKS=
printf 'S3_ENDPOINT=http://s3.example:9000\nR2_KEY=hunter2\nR2_EMPTY=\n' > "$T/src/.env"
side() { FAKE_CONFIG=$1 cli side check "$D"; }

cat > "$T/clean.json" << EOF2
{"services":{"web":{"image":"nginx","container_name":"qpside-web","ports":[{"target":80,"published":"18080"}],
 "network_mode":"container:qpside-db",
 "volumes":[{"type":"volume","source":"data","target":"/d"},
   {"type":"bind","source":"$D/data","target":"/a"},{"type":"bind","source":"$D/x/../data","target":"/b"},
   {"type":"bind","source":"/etc/hosts","target":"/h"}],
 "environment":{"FOO":"bar","R2_KEY":"other","R2_EMPTY":""}},
 "sp":{"image":"quantum-pipeline-spark:4.0.2-python3.12"},
 "ml":{"image":"x","container_name":"ml-kafka","ports":[{"target":9092,"published":"9092"}]}},
 "volumes":{"data":{"name":"qpside-side-test_data"}},"networks":{"default":{"name":"qpside-side-test_default"}}}
EOF2
check "side check: no side.override.yml" "$(cli side check "$D" 2>&1 | cut -c1-14)" $'FAIL\tcompose\tn'
: > "$D/compose/side.override.yml"
out=$(side "$T/clean.json"); rc=$?
check "side check: clean: rc" "$rc" "0"
check "side check: clean (a name or port clash is compose's to refuse)" "$out" $'INFO\timage\tsp: uses quantum-pipeline-spark:4.0.2-python3.12 without building it\nOK'

cat > "$T/bad.json" << EOF2
{"services":{
 "h":{"image":"x","network_mode":"host"},
 "c":{"image":"x","network_mode":"container:ml-kafka"},
 "b1":{"image":"x","volumes":[{"type":"bind","source":"$T/bench","target":"/b"}]},
 "b2":{"image":"x","volumes":[{"type":"bind","source":"$D/../src/./quantum-pipeline/../../bench/t","target":"/b"}]},
 "b3":{"image":"x","volumes":[{"type":"bind","source":"../src","target":"/b"}]},
 "af":{"image":"quantum-pipeline:gpu","build":{"context":"."},
   "volumes":[{"type":"bind","source":"/var/run/docker.sock","target":"/var/run/docker.sock"}],
   "environment":{"URL":"http://s3.example:9000","R2_KEY":"hunter2"}},
 "ml":{"image":"ml-airflow:1","build":{"context":"."}}},
 "volumes":{"d":{"name":"quantum-ml-data"},"e":{"name":"ml_airflow"},"f":{"name":"quantum-garage-x"}},
 "networks":{"n":{"name":"quantum-ml-network"}}}
EOF2
out=$(side "$T/bad.json"); rc=$?
check "side check: bad: rc" "$rc" "1"
check "side check: network_mode host" "$(grep -c $'^FAIL\tnetwork_mode\th: host' <<< "$out")" "1"
check "side check: network_mode container:ml-*" "$(grep -c $'^FAIL\tnetwork_mode\tc: container:ml-kafka' <<< "$out")" "1"
check "side check: bind into the bench" "$(grep -c $'^FAIL\tbind\tb1: ' <<< "$out")" "1"
check "side check: bind resolved through .." "$(grep -c $'^FAIL\tbind\tb2: '"$T/bench/t " <<< "$out")" "1"
check "side check: relative bind resolved against DIR" "$(grep -c $'^FAIL\tbind\tb3: '"$T/src " <<< "$out")" "1"
check "side check: docker.sock" "$(grep -c $'^FAIL\tdocker.sock\taf ' <<< "$out")" "1"
check "side check: protected image with build" "$(grep -c $'^FAIL\timage\taf: builds quantum-pipeline:gpu' <<< "$out")" "1"
check "side check: ml-* image with build" "$(grep -c $'^FAIL\timage\tml: builds ml-airflow:1' <<< "$out")" "1"
check "side check: S3_ENDPOINT" "$(grep -c $'^FAIL\tenv\taf: URL is the bench S3_ENDPOINT' <<< "$out")" "1"
check "side check: R2 value" "$(grep -c $'^FAIL\tenv\taf: R2_KEY is the bench value' <<< "$out")" "1"
check "side check: volumes" "$(grep -c $'^FAIL\tvolume\t' <<< "$out")" "3"
check "side check: network" "$(grep -c $'^FAIL\tnetwork\tn: quantum-ml-network' <<< "$out")" "1"
check "side check: nothing else" "$(grep -c '^FAIL' <<< "$out")" "14"
check "side check: no secret printed" "$(grep -c hunter2 <<< "$out")" "0"
check "side check: no OK" "$(grep -c '^OK' <<< "$out")" "0"

# a run in progress: the bench lock is held
echo "r1 123 456" > "$B/.active"
bash -c 'exec 9< "$1"; flock -n 9 && exec sleep 30' _ "$B/.lock" &
HOLD=$!
sleep 0.3
out=$(side "$T/clean.json"); rc=$?
check "side check: lock held: rc" "$rc" "1"
check "side check: lock held: names the run" "$(grep -c $'^FAIL\tlock\tthe bench lock is held by r1:' <<< "$out")" "1"
kill "$HOLD"; wait "$HOLD" 2> /dev/null
out=$(side "$T/clean.json"); rc=$?
check "side check: lock free again" "$rc" "0"

echo 'GPU_QP_SIDE_MARGIN_GB=999999999' >> "$LIB/bench.env"
out=$(side "$T/clean.json"); rc=$?
check "side check: disk: rc" "$rc" "1"
check "side check: disk" "$(grep -c $'^FAIL\tdisk\t' <<< "$out")" "1"
check "side check: usage" "$(refused cli side | cut -c1-4)" "rc=2"
check "side check: no such dir" "$(refused cli side check "$T/none")" "rc=1 [FAIL] no such directory: $T/none"

finish
