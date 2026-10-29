#!/usr/bin/env bash
# status.sh: status of a benchmark run and the GPU worker, as a small terminal tool.
#
#   gpu-qp status [--run NAME] [--section[ topic]]... [--no-color] [phase...]
#
# The run is --run NAME, else the one holding the bench lock, else bench/current. Sections
# (default: host proc phases errors eta):
#   --host            host + GPU
#   --proc            processes
#   --phases          per-phase lane progress        (phases: the run's, else the dirs with a state.tsv)
#   --pipe [topic]    pipeline: kafka | schema | garage   (no topic = all, extended)
#   --airflow [topic] airflow:  containers | dags | runs | tasks  (no topic = all)
#   --monitor         monitoring artefacts
#   --extract         extraction progress
#   --errors          newest error per lane
#   --eta             remaining wall-clock estimate per lane (eta.py beside this script)
#   --iceberg [refresh]  Iceberg table row counts (cached; `refresh` re-queries Spark, ~1 min)
#   --batch           the product batch generator's own --status (gen/ml_batch_state.json)
#   --all             every section
#
# Examples:
#   gpu-qp status                          # the default view of the active run
#   gpu-qp status --run final --phases A2  # phase A2 of run final
#   gpu-qp status --pipe kafka             # just the Kafka detail
#   gpu-qp status --pipe --airflow dags    # pipeline + dag table
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
. "$HERE/env.sh"
ROOT=$GPU_QP_SOURCE
LANES=(cpu-aer gpu1 gpu2 analytic)

WANT=()
PHASES=()
RUN_ARG=
PIPE_TOPICS=()
AIR_TOPICS=()
ICEBERG_TOPICS=()
NO_COLOR_SET=""
ICEBERG_TABLES="molecules ansatz_info performance_metrics vqe_results initial_parameters optimal_parameters vqe_iterations iteration_parameters hamiltonian_terms processing_metadata"
ICEBERG_CACHE="$GPU_QP_BENCH_ROOT/iceberg-counts.txt"

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  a=$1; shift
  case "$a" in
    --run) [ $# -ge 1 ] || { echo "gpu-qp status: --run needs a name" >&2; exit 2; }; RUN_ARG=$1; shift ;;
    --all) WANT=(host proc phases pipe airflow monitor extract errors eta iceberg batch) ;;
    --host|--proc|--phases|--monitor|--extract|--errors|--eta|--batch) WANT+=("${a#--}") ;;
    --pipe) WANT+=(pipe); case "${1:-}" in ""|-*) ;; *) PIPE_TOPICS+=("$1"); shift ;; esac ;;
    --airflow) WANT+=(airflow); case "${1:-}" in ""|-*) ;; *) AIR_TOPICS+=("$1"); shift ;; esac ;;
    --iceberg) WANT+=(iceberg); case "${1:-}" in ""|-*) ;; *) ICEBERG_TOPICS+=("$1"); shift ;; esac ;;
    --no-color) NO_COLOR_SET=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "gpu-qp status: unknown option: $a" >&2; exit 2 ;;
    *) PHASES+=("$a") ;;
  esac
done
[ ${#WANT[@]} -eq 0 ] && WANT=(host proc phases errors eta)

# The run to report on; no run is not an error for status.
resolve_run "$RUN_ARG" || { [ $? -eq 2 ] && exit 2; exit 0; }
BENCH=$RUN_DIR
[ ${#PHASES[@]} -eq 0 ] && read -ra PHASES < <(run_phases "$BENCH")

want() { local x; for x in "${WANT[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
# sub_want <topic> [topic...] — true when no topics given (all), or the topic is listed
sub_want() {
  local topic=$1; shift
  [ $# -eq 0 ] && return 0
  local t; for t in "$@"; do [ "$t" = "$topic" ] && return 0; done
  return 1
}

# --- colour (auto-off when piped, or NO_COLOR / --no-color) ---
if [ -t 1 ] && [ -z "$NO_COLOR_SET" ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'
  CY=$'\033[36m'; GR=$'\033[32m'; YE=$'\033[33m'; RE=$'\033[31m'
else
  B=; D=; R=; CY=; GR=; YE=; RE=
fi

IW=9
hdr() {
  local n=$1 p l r inner
  p=$((IW - ${#n})); [ "$p" -lt 2 ] && p=2
  l=$((p / 2)); r=$((p - l))
  printf -v inner '%*s%s%*s' "$l" '' "$n" "$r" ''
  printf '\n%s[%s]%s\n' "$B$CY" "$inner" "$R"
}
# kv <label> <value> [colour]   — aligned two-column line
kv() {
  local label=$1 value=$2 colour=${3:-}
  if [ -n "$colour" ]; then
    printf '  %s%-16s%s%s%s%s\n' "$D" "$label" "$R" "$colour" "$value" "$R"
  else
    printf '  %s%-16s%s%s\n' "$D" "$label" "$R" "$value"
  fi
}

# First line: the run, its state and, while it runs, the phase of its newest cell log.
state=$(run_state "$BENCH")
line="run: $RUN ($BENCH)  $state"
case $state in
  RUNNING | ORPHANED)
    newest=$(newest_log 3 "$BENCH")
    [ -n "$newest" ] && line+="  phase $(basename "$(dirname "$(dirname "${newest#* }")")")"
    since=$(sed -n 's/^\[supervise\] start \([^ ]*\) .*/\1/p;T;q' "$BENCH/supervise.log" 2> /dev/null)
    [ -n "$since" ] && line+="  since $since"
    age=$(stalled_min "$BENCH") && line+="  stalled ${age}m"
    ;;
esac
# The host-wide power-off cap (stop --by), and every run queued behind another (resume).
if pidfile_alive "$GPU_QP_BENCH_ROOT/stop.by"; then
  read -r _ e _ < "$GPU_QP_BENCH_ROOT/stop.by"
  line+="  stop by $(date -d "@$e" '+%a %F %H:%M')"
fi
printf '%s\n' "$line"
# The kernel guard's pin (bench/kernel.pin: kernel, then the pending runs).
if [ -r "$GPU_QP_BENCH_ROOT/kernel.pin" ] && read -r k pend < "$GPU_QP_BENCH_ROOT/kernel.pin"; then
  printf 'kernel pinned to %s (pending: %s)\n' "$k" "${pend// /, }"
fi
for f in "$GPU_QP_BENCH_ROOT"/*/start.after; do
  if pidfile_alive "$f"; then
    read -r _ e _ < "$f"
    printf 'run %s: start after %s\n' "$(basename "$(dirname "$f")")" "$e"
  fi
done
printf '%sgpu-qp status%s  %s  %s\n' "$B" "$R" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)"

# True when the Docker daemon answers; the first failure prints the one `docker: unreachable` line.
DOCKER_UP=
docker_up() {
  if [ -z "$DOCKER_UP" ]; then
    if timeout "$GPU_QP_PROBE_TIMEOUT" docker info > /dev/null 2>&1; then DOCKER_UP=1
    else DOCKER_UP=0; printf '\n  docker: unreachable\n'; fi
  fi
  [ "$DOCKER_UP" = 1 ]
}

if want host; then
  hdr HOST
  printf '  cores %s   load %s   mem %s free   disk %s free (%s)\n' \
    "$(nproc)" "$(awk '{print $1,$2,$3}' /proc/loadavg)" \
    "$(free -h | awk 'NR==2{print $7}')" \
    "$(df -h / | awk 'NR==2{print $4}')" "$(df -h / | awk 'NR==2{print $5}')"
  if gpus=$(timeout "$GPU_QP_PROBE_TIMEOUT" nvidia-smi \
    --query-gpu=index,name,utilization.gpu,memory.used --format=csv,noheader 2> /dev/null); then
    awk -F', ' -v d="$D" -v r="$R" '{printf "  %sgpu%s%s  %-18s %-4s %s\n", d, $1, r, $2, $3, $4}' <<< "$gpus"
  else
    printf '  gpu: unreachable\n'
  fi
fi

if want proc; then
  hdr PROC
  ps -eo args > /tmp/.qs.$$
  printf '  supervisor %s   driver %s   lanes %s   sampler %s\n' \
    "$(grep -cE '^bash .*/(gpu-qp-)?supervise\.sh' /tmp/.qs.$$)" \
    "$(grep -cE '^bash .*/(gpu-qp-)?phase\.sh' /tmp/.qs.$$)" \
    "$(grep -cE '^bash .*/(gpu-qp-)?lane\.sh' /tmp/.qs.$$)" \
    "$(grep -cE '^bash .*/(gpu-qp-)?sample\.sh run' /tmp/.qs.$$)"
  rm -f /tmp/.qs.$$
fi

# Per-cell spools: one line per phase/lane, "<phase>/<lane>  <files> file(s)  <cell>(<n>) ...".
# Read-only; prints nothing when no cell spooled.
cell_spools() {
  local d n rel ph ln cell
  for d in "$BENCH"/*/*/*.gen/undelivered; do
    [ -d "$d" ] || continue
    # shellcheck disable=SC2012
    n=$(ls -A "$d" 2>/dev/null | wc -l)
    [ "$n" -gt 0 ] || continue
    rel=${d#"$BENCH"/}
    IFS=/ read -r ph ln cell _ <<< "$rel"
    printf '%s/%s\t%s\t%s\n' "$ph" "$ln" "${cell%.gen}" "$n"
  done | awk -F'\t' '{t[$1]+=$3; c[$1]=c[$1] " " $2 "(" $3 ")"; if(!($1 in o)){o[$1]=++k; key[k]=$1}}
    END{for(i=1;i<=k;i++) printf "%s  %d file(s) in%s\n", key[i], t[key[i]], c[key[i]]}'
}

# phase_lanes PHASE: "lane expected" per lane in table order, from the run's lib/lanes.tsv; without
# the table (a legacy run) just the lanes found in state.tsv.
phase_lanes() {
  local cells
  if cells=$(python3 "$HERE/lanes.py" "$BENCH/lib/lanes.tsv" cells "$1" 2> /dev/null); then
    awk -F'\t' '!($2 in n) { o[++k] = $2 } { n[$2]++ } END { for (i = 1; i <= k; i++) print o[i], n[o[i]] }' <<< "$cells"
  else
    awk -F'\t' '{ print $1 }' "$BENCH/$1/state.tsv" | sort -u
  fi
}

if want phases; then
  hdr PHASES
  for p in "${PHASES[@]}"; do
    s=$BENCH/$p/state.tsv
    if [ ! -f "$s" ]; then printf '  %s  %snot started%s\n' "$p" "$D" "$R"; continue; fi
    row=""
    while read -r lane exp; do
      read -r dn un fa < <(state_counts "$s" "$lane")
      dn=$((dn + un))
      col=""; [ "$dn" = "$exp" ] && col=$GR
      row="$row$lane ${col}${dn}${exp:+/$exp}${col:+$R}"
      [ "$fa" -gt 0 ] && row="$row ${RE}failed $fa$R"
      row="$row  "
    done < <(phase_lanes "$p")
    printf '  %s  %s\n' "$p" "${row%  }"
    printf '  %slast%s  %s\n' "$D" "$R" \
      "$(tail -1 "$s" | awk -F'\t' '{printf "%s %s seed%s %s",$1,$2,$3,$4}')"
  done
fi

if want pipe && docker_up; then
  KAFKA_BS=kafka:9092
  KCLI=/opt/kafka/bin
  if sub_want kafka "${PIPE_TOPICS[@]}"; then
    hdr KAFKA
    kv topic "$(docker exec ml-kafka $KCLI/kafka-topics.sh --bootstrap-server $KAFKA_BS \
      --list 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
    printf '  %soffsets%s\n' "$D" "$R"
    docker exec ml-kafka $KCLI/kafka-get-offsets.sh --bootstrap-server $KAFKA_BS \
      --topic experiment.vqe 2>/dev/null | sed 's/^/    /'
    printf '  %sconsumer groups%s\n' "$D" "$R"
    groups=$(docker exec ml-kafka $KCLI/kafka-consumer-groups.sh --bootstrap-server $KAFKA_BS \
      --list 2>/dev/null)
    if [ -n "$groups" ]; then
      for g in $groups; do
        lag=$(docker exec ml-kafka $KCLI/kafka-consumer-groups.sh --bootstrap-server $KAFKA_BS \
          --describe --group "$g" 2>/dev/null | awk 'NR>1{s+=$6} END{print s+0}')
        printf '    %-24s %slag %s%s\n' "$g" "$D" "$lag" "$R"
      done
    else
      printf '    %snone%s\n' "$D" "$R"
    fi
  fi

  if sub_want schema "${PIPE_TOPICS[@]}"; then
    hdr SCHEMA
    subs=$(curl -sS -m 2 http://localhost:8081/subjects 2>/dev/null)
    n=$(printf '%s' "$subs" | tr -cd '"' | wc -c)
    kv subjects "$((n / 2))"
    if command -v jq >/dev/null 2>&1; then
      printf '%s' "$subs" | jq -r '.[]?' 2>/dev/null | while read -r s; do
        latest=$(curl -sS -m 2 "http://localhost:8081/subjects/$s/versions/latest" 2>/dev/null)
        printf '    %-32s %s\n' "$s" \
          "$(printf '%s' "$latest" | jq -r '"id \(.id)  v\(.version)"' 2>/dev/null)"
      done
    fi
  fi

  if sub_want garage "${PIPE_TOPICS[@]}"; then
    hdr GARAGE
    # .env decides which store the stack writes to; an external one is read over S3.
    s3_endpoint=$(grep -E '^S3_ENDPOINT=' "$ROOT/.env" 2>/dev/null | cut -d= -f2-)
    s3_key=$(grep -E '^S3_ACCESS_KEY=' "$ROOT/.env" 2>/dev/null | cut -d= -f2-)
    s3_secret=$(grep -E '^S3_SECRET_KEY=' "$ROOT/.env" 2>/dev/null | cut -d= -f2-)
    s3_region=$(grep -E '^S3_REGION=' "$ROOT/.env" 2>/dev/null | cut -d= -f2-)
    if [ -n "$s3_endpoint" ] && [ "$s3_endpoint" != "http://garage:3901" ]; then
      kv endpoint "$s3_endpoint  (external, key ${s3_key:0:10}...)"
      printf '  %sbuckets%s\n' "$D" "$R"
      for b in raw-results features warehouse mlflow-artifacts; do
        n=$(curl -s -m 2 --aws-sigv4 "aws:amz:${s3_region:-garage}:s3" --user "$s3_key:$s3_secret" \
          "$s3_endpoint/$b?list-type=2" | grep -o '<KeyCount>[0-9]*' | cut -c11-)
        printf '    %-18s objects: %s\n' "$b" "${n:-?}"
      done
    else
      kv node "$(docker exec ml-garage /garage status 2>/dev/null \
        | awk '/^[0-9a-f]{16}/{print $1"  "$4"  "$6" "$7}' | head -1)"
      kv key "$(docker exec ml-garage /garage key list 2>/dev/null \
        | awk 'NR>1 && NF{print $1"  "$3}' | head -1)"
      printf '  %sbuckets%s\n' "$D" "$R"
      for b in raw-results features warehouse mlflow-artifacts; do
        info=$(docker exec ml-garage /garage bucket info "$b" 2>/dev/null \
          | grep -E 'Objects:|Size:' | tr '\n' ' ' | tr -s ' ' | sed 's/ *$//')
        printf '    %-18s %s\n' "$b" "$info"
      done
    fi
  fi

  # shellcheck disable=SC2012
  undel=$(ls -A "$ROOT/gen/undelivered" 2>/dev/null | wc -l)
  if [ "$undel" -gt 0 ]; then
    printf '  %sundelivered %s file(s)%s\n' "$RE" "$undel" "$R"
  else
    printf '  %sundelivered none%s\n' "$GR" "$R"
  fi
  cells=$(cell_spools)
  if [ -n "$cells" ]; then
    while read -r l; do printf '  %sundelivered (cells) %s%s\n' "$RE" "$l" "$R"; done <<< "$cells"
  fi
fi

if want airflow && docker_up; then
  hdr AIRFLOW
  if sub_want containers "${AIR_TOPICS[@]}"; then
    code=$(curl -sS -m 2 -o /dev/null -w '%{http_code}' \
      http://localhost:8084/api/v2/monitor/health 2>/dev/null)
    if [ "$code" = 200 ]; then col=$GR; else col=$RE; fi
    kv apiserver "$code" "$col"
    kv containers "$(docker compose -p ml ps --format '{{.Name}} {{.Status}}' 2>/dev/null \
      | grep -c airflow) running / $(docker compose -p ml ps --format '{{.Name}} {{.Status}}' \
      2>/dev/null | grep airflow | grep -c healthy) healthy"
  fi

  if sub_want dags "${AIR_TOPICS[@]}"; then
    if docker exec ml-airflow-scheduler airflow dags list > /tmp/.qd.$$ 2>/dev/null; then
      printf '  %sdags%s\n' "$D" "$R"
      grep '|' /tmp/.qd.$$ | tail -n +3 | while IFS='|' read -r id _ _ paused _ _; do
        id=${id// /}
        paused=${paused// /}
        if [ "$paused" = True ]; then
          printf '    %-30s %spaused%s\n' "$id" "$D" "$R"
        else
          printf '    %-30s %sactive%s\n' "$id" "$GR" "$R"
        fi
      done
      reg=$(grep '|' /tmp/.qd.$$ | tail -n +3 | grep -c .)
      files=$(docker exec ml-airflow-scheduler sh -c \
        'ls /opt/airflow/dags/*.py 2>/dev/null | wc -l' 2>/dev/null)
      [ "$reg" -lt "${files:-0}" ] && \
        printf '    %snote%s  registry still filling (%s of %s)\n' "$YE" "$R" "$reg" "$files"
    else
      printf '  %sdags%s  (scheduler CLI unavailable)\n' "$D" "$R"
    fi
    rm -f /tmp/.qd.$$
  fi

  if sub_want runs "${AIR_TOPICS[@]}"; then
    printf '  %sruns%s\n' "$D" "$R"
    runs=$(docker exec -i ml-postgres psql -U airflow -d airflow -tA -c \
      "select dag_id, state, coalesce(round(extract(epoch from (end_date - start_date))), 0) from dag_run order by start_date desc nulls last limit 6" 2>/dev/null)
    if [ -n "$runs" ]; then
      printf '%s\n' "$runs" | awk -F'|' '{printf "    %-30s %-10s %ss\n", $1, $2, $3}'
    else
      printf '    %snone%s\n' "$D" "$R"
    fi
  fi

  if sub_want tasks "${AIR_TOPICS[@]}"; then
    printf '  %stasks%s\n' "$D" "$R"
    tasks=$(docker exec -i ml-postgres psql -U airflow -d airflow -tA -c \
      "select dag_id, run_id, task_id, state, try_number, coalesce(round(extract(epoch from (end_date - start_date))), 0) from task_instance order by start_date desc nulls last limit 8" 2>/dev/null)
    if [ -n "$tasks" ]; then
      printf '%s\n' "$tasks" \
        | awk -F'|' '{printf "    %-26s %-24s %-14s try%s %ss\n", $1, $3, $4, $5, $6}'
      printf '  %sfailures%s\n' "$D" "$R"
      found=0
      while IFS='|' read -r d r t st _tn _sec; do
        case "$st" in failed|up_for_retry) ;; *) continue ;; esac
        found=1
        log=$(docker exec ml-airflow-scheduler sh -c \
          "ls -t /opt/airflow/logs/dag_id=$d/run_id=$r/task_id=$t/*.log 2>/dev/null | head -1" 2>/dev/null)
        msg=$(docker exec ml-airflow-scheduler sh -c \
          "grep -m1 -oE 'unresolved dependency[^\"]{0,55}|Error code is: [0-9]+|KeyError[^\"]{0,25}' $log 2>/dev/null" \
          2>/dev/null | head -1)
        printf '    %-38s %-14s %s\n' "$d/$t" "$st" "${msg:-(see task log)}"
      done <<< "$tasks"
      [ "$found" -eq 0 ] && printf '    %snone%s\n' "$D" "$R"
    else
      printf '    %snone%s\n' "$D" "$R"
    fi
  fi
fi

if want monitor; then
  hdr MONITOR
  first=1
  for f in "$ROOT"/gen/performance_metrics/*.jsonl; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .jsonl | sed 's/system_metrics_//')
    if [ "$first" = 1 ]; then
      printf '  metrics   %-18s %s lines\n' "$name" "$(wc -l < "$f")"
      first=0
    else
      printf '            %-18s %s lines\n' "$name" "$(wc -l < "$f")"
    fi
  done
  [ "$first" = 1 ] && printf '  metrics   %s(none yet)%s\n' "$D" "$R"
  for p in "${PHASES[@]}"; do
    [ -f "$BENCH/$p/nvidia.csv" ] && printf '  sampler   %-18s %s nvidia / %s loadavg rows\n' \
      "$p" "$(($(wc -l < "$BENCH/$p/nvidia.csv") - 1))" \
      "$(($(wc -l < "$BENCH/$p/loadavg.csv") - 1))"
  done
fi

if want extract; then
  hdr EXTRACT
  if [ -f "$BENCH/out/runs.csv" ]; then
    kv runs.csv "$(($(wc -l < "$BENCH/out/runs.csv") - 1)) runs"
  else
    kv runs.csv "pending (extractor runs at phase end)" "$D"
  fi
  [ -f "$BENCH/supervise.done" ] && kv supervise "$(cat "$BENCH/supervise.done")" "$GR"
fi

if want eta; then
  hdr ETA
  if [ -f "$HERE/eta.py" ]; then
    for p in "${PHASES[@]}"; do
      [ -f "$BENCH/$p/state.tsv" ] || continue
      python3 "$HERE/eta.py" "$BENCH" "$p" | sed 's/^/  /'
    done
  else
    printf '  %s(eta.py not present next to the status script)%s\n' "$D" "$R"
  fi
fi

if want iceberg; then
  hdr ICEBERG
  if [ ${#ICEBERG_TOPICS[@]} -gt 0 ] && sub_want refresh "${ICEBERG_TOPICS[@]}" && docker_up; then
    printf '  %srefreshing via spark-sql (~1 min)...%s\n' "$D" "$R"
    sql=/tmp/.qiceberg.$$
    first=1
    for t in $ICEBERG_TABLES; do
      [ "$first" = 1 ] || printf 'union all '
      printf "select '%s' as tbl, count(*) as n from quantum_catalog.quantum_features.%s\n" "$t" "$t"
      first=0
    done > "$sql"
    printf 'order by tbl;\n' >> "$sql"
    out=$(docker exec -i ml-spark-master /opt/spark/bin/spark-sql \
      --conf spark.jars.ivy=/tmp/.ivy2 -S < "$sql" 2>/dev/null \
      | grep -E '^[a-z_]+	[0-9]+$')
    rm -f "$sql"
    if [ -n "$out" ]; then
      { date -u +%Y-%m-%dT%H:%M:%SZ; printf '%s\n' "$out"; } > "$ICEBERG_CACHE"
    fi
  fi
  if [ -f "$ICEBERG_CACHE" ]; then
    printf '  %ssnapshot%s  %s\n' "$D" "$R" "$(head -1 "$ICEBERG_CACHE")"
    tail -n +2 "$ICEBERG_CACHE" | awk -F'\t' '{printf "    %-24s %s\n", $1, $2}'
  else
    printf '  %s(no snapshot yet - run: gpu-qp status --iceberg refresh)%s\n' "$D" "$R"
  fi
fi

if want batch; then
  hdr BATCH
  if [ -f "$ROOT/scripts/generate_ml_batch.py" ]; then
    out=$(cd "$ROOT" && timeout 30 python3 scripts/generate_ml_batch.py --status 2>/dev/null \
      | grep -vE '^=+$' | sed '1,/VQE Batch Generation Status/d' | sed 's/^/  /')
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
    else
      printf '  %s(no status output)%s\n' "$D" "$R"
    fi
  else
    printf '  %s(generate_ml_batch.py not in the checkout)%s\n' "$D" "$R"
  fi
fi

if want errors; then
  hdr ERRORS
  found=0
  for p in "${PHASES[@]}"; do
    for lane in "${LANES[@]}"; do
      d=$BENCH/$p/$lane
      [ -d "$d" ] || continue
      # shellcheck disable=SC2012
      last=$(ls -t "$d"/*.log 2>/dev/null | head -1)
      [ -n "$last" ] || continue
      if grep -qE 'Traceback|PermissionError|InvalidSolverConfigError|KafkaProducerError' "$last"; then
        printf '  %s%s/%s%s  %s\n' "$RE" "$p" "$lane" "$R" \
          "$(grep -m1 -E 'Traceback|Error|error' "$last" | cut -c1-80)"
        found=1
      fi
    done
  done
  [ "$found" -eq 0 ] && printf '  %snone%s\n' "$GR" "$R"
fi
