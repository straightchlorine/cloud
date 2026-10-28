#!/usr/bin/env bash
# watch-run - babysit a long maintenance pass and hand control back when the pass
# needs attention.
#
# It samples media-status every INTERVAL seconds (read-only: media-status never
# invokes beets or docker), appends one line per sample to $SAMPLES, and exits on
# the first of these, so whoever started it is told:
#
#   10  the step marker changed     a phase boundary: look at what just started
#   20  the run died                no night.sh/media-sync left, no completion line
#   22  fd count high               approaching the per-container ceiling (65536)
#   23  stalled                     no new task for STALL_MIN minutes
#   24  wall-clock timeout          longer than TIMEOUT_H, something is wrong
#   30  finished                    the "night run complete" line appeared
#
# A long pass has two useful signals: the phase it is in, and whether it is still
# making progress. Everything else (503s, skipped files, a shrinking library.db) is
# expected noise.
#
# Usage, on the machine running the pass:
#   INTERVAL=60 nohup scripts/media/watch-run.sh >> /tmp/watch-run.out 2>&1 &
#
# ONCE=1 prints one sample and exits - for testing the parsing.
set -uo pipefail

STATUS="${STATUS:-/home/zweiss/stack/media-status}"
RUNLOG="${RUNLOG:-/mnt/data/logs/night.log}"
SAMPLES="${SAMPLES:-/mnt/data/logs/run-watch.log}"
INTERVAL="${INTERVAL:-60}"
STALL_MIN="${STALL_MIN:-25}"
FD_ALERT="${FD_ALERT:-50000}"
TIMEOUT_H="${TIMEOUT_H:-48}"

prev_marker=""
prev_walked=""
prev_dns=""
last_progress=$SECONDS
started=$SECONDS

sample() {
    local out
    out=$("$STATUS" 2>/dev/null) || true
    marker=$(printf '%s\n' "$out" | sed -n 's/^current  : //p')
    # just "3/5 --upgrade all": the full mode name overflows the sample columns
    step=$(printf '%s' "$marker" | sed 's/^=== [0-9T:+-]*  *//; s/media-sync  *//' | cut -c1-20)
    walked=$(printf '%s\n' "$out" | grep -oE '^tasks    : [0-9]+' | grep -oE '[0-9]+$')
    matched=$(printf '%s\n' "$out" | grep -oE '[0-9]+ matched' | grep -oE '[0-9]+')
    mb503=$(printf '%s\n' "$out" | grep -oE '[0-9]+ MB 503s' | grep -oE '[0-9]+')
    fds=$(printf '%s\n' "$out" | grep -oE 'fd=[0-9]+' | tail -1 | grep -oE '[0-9]+')
    db=$(printf '%s\n' "$out" | grep -oE '^db items : [0-9]+' | grep -oE '[0-9]+')
    if pgrep -f 'night\.sh|media-sync' >/dev/null 2>&1; then alive=1; else alive=0; fi
    walked=${walked:-0}
    fds=${fds:-0}
}

report() {  # <exit-code> <why>
    local line
    line="$(date -Is)  EXIT $1  $2  |  step='${step:-?}'  walked=${walked:-?} matched=${matched:-?} 503s=${mb503:-?} fds=${fds:-?} alive=${alive:-?} db=${db:-?}"
    printf '%s\n' "$line" | tee -a "$SAMPLES"
}

while true; do
    sample
    printf '%s  %-24s walked=%-6s matched=%-5s 503s=%-5s fds=%-6s alive=%s db=%s\n' \
        "$(date -Is)" "${step:-?}" "$walked" "${matched:-?}" "${mb503:-?}" "$fds" "$alive" "${db:-?}" \
        | tee -a "$SAMPLES"

    if [ "${ONCE:-0}" = "1" ]; then exit 0; fi

    # 1. phase boundary
    if [ -n "$prev_marker" ] && [ "$marker" != "$prev_marker" ]; then
        report 10 "step marker changed: '${step:-?}'"
        exit 10
    fi
    prev_marker="$marker"

    # 2. finished
    if grep -qa 'night run complete' "$RUNLOG" 2>/dev/null; then
        report 30 "completion line in $RUNLOG"
        exit 30
    fi

    # 3. died: nothing running, and no completion
    if [ "$alive" = "0" ]; then
        sleep 20; sample   # one confirmation sample: a gap between steps looks identical
        if [ "$alive" = "0" ]; then
            report 20 "no night.sh/media-sync process and no completion line"
            exit 20
        fi
    fi

    # 4. progress watchdog
    if [ "$walked" != "$prev_walked" ]; then
        prev_walked="$walked"
        last_progress=$SECONDS
    elif [ $(( (SECONDS - last_progress) / 60 )) -ge "$STALL_MIN" ]; then
        report 23 "no new task for ${STALL_MIN}m (walked=${walked})"
        exit 23
    fi

    # 5. fd ceiling watch: the limit is 65536, and this is what killed earlier runs
    if [ "$fds" -ge "$FD_ALERT" ] 2>/dev/null; then
        report 22 "fd count ${fds} >= ${FD_ALERT}"
        exit 22
    fi

    # 6. overall timeout
    if [ $(( (SECONDS - started) / 3600 )) -ge "$TIMEOUT_H" ]; then
        report 24 "wall-clock timeout after ${TIMEOUT_H}h"
        exit 24
    fi

    # 7. resolution failures: the failure mode that looks like success. The pass
    #    keeps logging "Skipping." while every lookup dies, so nothing else here
    #    notices - 3913 of them hid inside one run that looked healthy.
    dnsnow=$(grep -acE 'NameResolutionError|Failed to resolve|gaierror' "$RUNLOG" 2>/dev/null)
    dnsnow=${dnsnow:-0}
    if [ -n "$prev_dns" ] && [ "$dnsnow" -gt "$prev_dns" ] 2>/dev/null; then
        report 25 "resolution failures grew: ${prev_dns} -> ${dnsnow}"
        exit 25
    fi
    prev_dns="$dnsnow"

    sleep "$INTERVAL"
done
