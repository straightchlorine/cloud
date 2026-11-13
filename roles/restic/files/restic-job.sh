#!/usr/bin/env bash
# The restic engine's only script (roles/restic). Per-job config lives in
# /etc/restic/<job>.{env,password,sources,excludes,metered}; nothing here is per job.
#   restic-job run <job>               backup, forget, weekly prune + check
#   restic-job exec <job> <restic args> restic on the job's repository, no cache
#   restic-job gate <job>              ExecCondition= of skip_metered / skip_on_battery jobs
#   restic-job cron <job>              the cron (OpenRC) counterpart of the whole unit (root)
#   restic-job notify ok-<job>|fail-<job>  ntfy for OnSuccess=/OnFailure= (root)
#   restic-job storage <job>           Storage Box free-space check of an sftp job (the weekly step calls it)
#   restic-job freshness               ntfy for overdue or interrupted jobs and a full Storage Box (root),
#                                      at most one alert a day per condition
# run exits 0 (ok), 3 (snapshot saved, some files unreadable) or 1 (failed).
# gate exits 0 (go), 1 (skip this run, the journal or the cron log says why) or 255 (no such job: fails the
# unit); it checks every active NetworkManager connection, not only the primary one.
# freshness exits 0 (all fresh), 2 (alert delivered) or 1 (delivery failed).
# No set -e: every restic exit code is branched on explicitly.
set -uo pipefail

conf=/etc/restic
state=/var/lib/restic
bin=${RESTIC_JOB_BIN:-/usr/local/bin/restic} # test seam: molecule's stub restic
retry_sleep=${RESTIC_JOB_RETRY_SLEEP:-60}    # test seam: seconds between unlock attempts
power=${RESTIC_JOB_POWER_DIR:-/sys/class/power_supply} # test seam: a fake power_supply tree
logdir=/var/log/restic
alerts=/var/lib/restic-alerts                          # root-owned: the job's user cannot write to it
kill_after=${RESTIC_JOB_KILL_AFTER:-5m}                # test seam: cron wrapper's grace before SIGKILL

interrupted=0
child=0
job=
die_rc=1

log() { echo "restic-job: $*" >&2; }
die() {
    # A stop during shutdown loses the OnFailure= notification, because the notify unit
    # conflicts with shutdown.target. The marker lets freshness report the stop later.
    ((interrupted)) && [[ -n $job ]] && touch "$state/$job.interrupted"
    log "FAILED: $*"
    exit "$die_rc"
}

load() {
    job=$1
    [[ $job =~ ^[a-z0-9][a-z0-9-]*$ && -r $conf/$job.env ]] || die "no job '$job' in $conf"
    set -a
    # shellcheck source=/dev/null
    . "$conf/$job.env"
    set +a
    r=("$bin" --retry-lock 30m -o "sftp.args=-F $conf/ssh_config")
}

# True when $1 is older than $2 minutes. A stamp more than 5 minutes in the future also
# counts as old, because it was probably written before the clock synced on a Pi without RTC.
older() {
    [[ -n $(find "$1" -maxdepth 0 \( -mmin +"$2" -o -newermt "@$(($(date +%s) + 300))" \)) ]]
}

# restic deletes its repository lock when it receives SIGINT. KillMode=mixed delivers the
# stop signal to this script alone while ssh keeps running, so the script passes it on and
# waits until restic has cleaned up.
forward() {
    interrupted=1
    ((child)) && kill -INT "$child" 2>/dev/null
}

rr() {
    local rc
    ((interrupted)) && return 130
    "${r[@]}" "$@" &
    child=$!
    ((interrupted)) && kill -INT "$child" 2>/dev/null # the signal arrived before child was set
    while :; do
        wait "$child"
        rc=$?
        kill -0 "$child" 2>/dev/null || break
    done
    child=0
    return "$rc"
}

# A missing stamp is created and starts the clock, so a first run never also pays for a prune.
# The interval is a week minus a margin that absorbs the timer's RandomizedDelaySec.
due() {
    [[ -e $1 ]] || {
        touch "$1"
        return 1
    }
    older "$1" $((7 * 1440 - 60))
}

run_job() {
    load "$1"
    local p f rc i warn=0 steps=backup
    local -a src fresh keep
    r+=(--cleanup-cache) # exec runs with --no-cache, so only run cleans the cache
    # The tmp directory is made here, as the restic user: root-run Ansible never writes into a directory
    # the restic user owns, where a planted symlink could redirect it.
    [[ -d $TMPDIR ]] || mkdir -m 0700 "$TMPDIR" || die "cannot create $TMPDIR"
    # restic deletes its pack-file staging files itself; a killed run leaves them on a persistent disk.
    find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'restic-temp-*' -mmin +1440 -delete 2>/dev/null
    trap forward INT TERM
    rm -f "$state/$job.interrupted"

    mapfile -t src <"$conf/$job.sources"
    ((${#src[@]})) || die "$conf/$job.sources is empty"
    for p in "${src[@]}"; do
        [[ -e $p ]] || die "source missing: $p"
        if [[ -d $p && -z $(find "$p" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
            die "source is an empty directory (not mounted?): $p"
        fi
    done
    # Each path:hours pair names data another job writes, such as a database dump, that must be recent.
    read -ra fresh <<<"$RESTIC_JOB_FRESH"
    for f in "${fresh[@]}"; do
        p=${f%:*}
        [[ -e $p ]] || die "fresh path missing: $p"
        older "$p" $((${f##*:} * 60)) && die "$p not updated in the last ${f##*:} h (its writer did not run)"
    done

    # Unlock clears only stale locks, such as those left by a SIGKILL or a power cut.
    # Exit 1 here almost always means the network is not up yet after a boot-time catch-up run, so it is retried.
    # The restic exit codes 10 and 12 are configuration errors and fail at once.
    for i in 1 2 3 4 5; do
        rr unlock
        rc=$?
        case $rc in
        0) break ;;
        1) ;;
        10) die "no repository at $RESTIC_REPOSITORY" ;;
        12) die "wrong password for $RESTIC_REPOSITORY" ;;
        *) die "restic unlock exited $rc" ;;
        esac
        ((interrupted)) && die "stopped before the backup"
        ((i < 5)) || die "repository unreachable (restic exit $rc)"
        log "unlock failed (exit $rc), retrying"
        sleep "$retry_sleep" &
        wait $! # returns at once when the trap fires
    done
    ((interrupted)) && die "stopped before the backup"

    read -ra extra_tags <<<"$RESTIC_JOB_TAGS"
    tag_args=()
    for t in "${extra_tags[@]}"; do tag_args+=(--tag "$t"); done
    rr backup --host "$RESTIC_JOB_HOST" --tag "$job" "${tag_args[@]}" --exclude-caches \
        --files-from-verbatim "$conf/$job.sources" --exclude-file "$conf/$job.excludes"
    rc=$?
    case $rc in
    0) ;;
    3)
        warn=1
        log "snapshot saved, but some source files could not be read (exit 3)"
        ;;
    *) die "backup failed (restic exit $rc)" ;;
    esac
    touch "$state/$job.ok"
    ((interrupted)) && die "stopped after the snapshot was saved"

    # Grouping by host alone keeps one retention chain across changes to the source list.
    # The --host filter leaves other hosts' snapshots in the same repository untouched.
    # Only the job tag scopes forget, so an OS upgrade (a new OS tag) never splits the retention chain;
    # --keep-tag pins what a person tagged by hand.
    read -ra keep <<<"$RESTIC_JOB_KEEP"
    rr forget --host "$RESTIC_JOB_HOST" --tag "$job" --group-by host --keep-tag keep "${keep[@]}" ||
        die "forget failed (the snapshot itself was saved)"
    steps+=,forget

    if due "$state/$job.pruned"; then
        rr prune || die "prune failed"
        touch "$state/$job.pruned"
        steps+=,prune
    fi
    if due "$state/$job.checked"; then
        rr check --read-data-subset 5% || die "check failed: the repository may be damaged"
        touch "$state/$job.checked"
        steps+=,check
    fi
    # The first run checks at once; the failed check is retried by the next run, because its stamp is not touched.
    if [[ $RESTIC_REPOSITORY == sftp:* ]] && { [[ ! -e $state/$job.spacechecked ]] || due "$state/$job.spacechecked"; }
    then
        storage_check && touch "$state/$job.spacechecked" && steps+=,space
    fi
    log "done ($steps)"
    exit $((warn ? 3 : 0))
}

# Reads the Storage Box's free space with the sftp df command (statvfs@openssh.com) and leaves <job>.storage
# ("<used %> <minimum free %>") when less than the job's minimum is free, or removes it. The alert is not sent
# here but by the root freshness run: the job runs sandboxed (ProtectSystem=strict, only its state and cache
# directories writable), and a failure of this check must not be able to touch the backup's outcome.
# A failed df returns 1 and changes nothing: monitoring must never fail a backup.
storage_check() {
    local out size used pct
    [[ $RESTIC_REPOSITORY == sftp:* ]] || return 0
    out=$(timeout 60 sftp -F "$conf/ssh_config" -b - hetzner-storage <<<df 2>&1) || {
        log "storage check: sftp df failed: ${out//$'\n'/ }"
        return 1
    }
    # df prints a header and one row: size, used, avail, (root), %capacity, in KiB.
    read -r size used < <(awk 'NF >= 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { s = $1; u = $2 } END { print s, u }' \
        <<<"$out")
    if [[ ! $size =~ ^[0-9]+$ || ! $used =~ ^[0-9]+$ ]] || ((size == 0)); then
        log "storage check: cannot read sftp df output: ${out//$'\n'/ }"
        return 1
    fi
    pct=$(((used * 100 + size / 2) / size))
    # Compared exactly; pct is only the rounded figure for the message.
    if (((size - used) * 100 < RESTIC_JOB_MIN_FREE_PERCENT * size)); then
        echo "$pct $RESTIC_JOB_MIN_FREE_PERCENT" >"$state/$job.storage"
        log "Storage Box at $pct% used (alert below $RESTIC_JOB_MIN_FREE_PERCENT% free)"
    else
        rm -f "$state/$job.storage"
    fi
}

skip() {
    log "skipped: $*"
    exit 1
}

# Skips when the job's connection list names $1.
listed() {
    grep -Fxq -- "$1" "$conf/$job.metered" && skip "connection '$1' is listed as metered"
}

# Reads a NetworkManager property into $nm as the "data" member of busctl's JSON reply.
# JSON keeps UTF-8 names raw, where the default text output C-escapes them.
# The run is skipped when the property cannot be read.
nm_get() {
    local out
    out=$(busctl --json=short get-property org.freedesktop.NetworkManager "$@" 2>&1) ||
        skip "NetworkManager unreachable: ${out//$'\n'/ }"
    nm=$(sed -e 's/^{"type":"[a-z]*","data"://' -e 's/}$//' <<<"$out")
}

# True when NetworkManager reports the device at $1 as metered, either yes (1) or guess-yes (3).
metered() {
    nm_get "$1" org.freedesktop.NetworkManager.Device Metered
    [[ $nm == 1 || $nm == 3 ]]
}

# The NetworkManager reader for systemd hosts, which always have busctl.
gate_busctl() {
    local p id type v n=0 nmo=/org/freedesktop/NetworkManager
    local -a act devs
    nm_get $nmo org.freedesktop.NetworkManager Metered
    [[ $nm == 1 || $nm == 3 ]] && skip "NetworkManager reports a metered link (Metered=$nm)"
    nm_get $nmo org.freedesktop.NetworkManager ActiveConnections
    # Every active connection is checked, not only the primary one. Under a VPN the primary is the
    # tunnel, whose name and Metered value say nothing about the hotspot underneath.
    mapfile -t act < <(grep -o '/[^"]*' <<<"$nm")
    for p in "${act[@]}"; do
        nm_get "$p" org.freedesktop.NetworkManager.Connection.Active Type
        type=$(tr -d '"' <<<"$nm")
        # Bridges, tunnels and the like are no uplink: a docker bridge is up on an offline host.
        [[ $type =~ ^(bridge|tun|veth|dummy|loopback)$ ]] && continue
        n=$((n + 1))
        nm_get "$p" org.freedesktop.NetworkManager.Connection.Active Id
        # Undo the JSON quoting of the two characters it escapes in a printable name.
        id=$(sed -e 's/^"//' -e 's/"$//' -e 's/\\\([\\"]\)/\1/g' <<<"$nm")
        listed "$id"
        nm_get "$p" org.freedesktop.NetworkManager.Connection.Active Devices
        mapfile -t devs < <(grep -o '/[^"]*' <<<"$nm")
        for v in "${devs[@]}"; do
            ! metered "$v" || skip "link of '$id' is metered"
        done
    done
    ((n)) || skip "no active network connection"
}

# The NetworkManager reader for hosts without busctl (OpenRC): the same decisions from nmcli.
# --escape no keeps colons and backslashes of a connection name raw.
# The run is skipped when nmcli is missing or NetworkManager does not answer.
gate_nmcli() {
    local out line name type dev_m dev_c
    local n=0 ignored=''
    command -v nmcli >/dev/null || skip "NetworkManager unreachable: nmcli not found"
    out=$(nmcli --terse --escape no --fields NAME,TYPE connection show --active 2>&1) ||
        skip "NetworkManager unreachable: ${out//$'\n'/ }"
    # Bridges, tunnels and the like are no uplink: counting them would let an offline host start a run.
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        name=${line%:*} type=${line##*:}
        if [[ $type =~ ^(bridge|tun|veth|dummy|loopback)$ ]]; then
            ignored+=$name$'\n'
            continue
        fi
        n=$((n + 1))
        listed "$name"
    done <<<"$out"
    ((n)) || skip "no active network connection"
    out=$(nmcli --terse --escape no --fields GENERAL.METERED,GENERAL.CONNECTION device show 2>&1) ||
        skip "NetworkManager unreachable: ${out//$'\n'/ }"
    # The two fields of one device may come in either order, so a device is judged once both are read.
    # A device with no connection (shown as --) or only an ignored one is not a link in use.
    dev_m='' dev_c=''
    while IFS= read -r line; do
        case $line in
        GENERAL.METERED:*) dev_m=${line#*:} ;;
        GENERAL.CONNECTION:*) dev_c=${line#*:} ;;
        esac
        [[ -n $dev_m && -n $dev_c ]] || continue
        if [[ $dev_c != -- && $dev_m == yes* ]] && ! grep -Fxq -- "$dev_c" <<<"$ignored"; then
            skip "link of '$dev_c' is metered"
        fi
        dev_m='' dev_c=''
    done <<<"$out"
}

# True when the machine is not running on a discharging battery. A host with no battery (a desktop) is on AC.
# Only the battery decides: a USB-C charger reports as type USB, and "Not charging" or "Full" at the charge limit
# is still mains power.
on_ac() {
    local s
    for s in "$power"/*; do
        [[ -r $s/type && $(<"$s/type") == Battery ]] || continue
        [[ -r $s/status && $(<"$s/status") == Discharging ]] && return 1
    done
    return 0
}

# Fails closed: the run is skipped when NetworkManager cannot be read or reports no active connection.
# A job that never finds an unmetered link gets no new stamp, so freshness reports it.
gate() {
    die_rc=255 # exit 1 would read as a skip; a missing job must fail the unit
    load "$1"
    die_rc=1
    # The timer of a gated job fires hourly, and this check lets a run through at most once per 20 h.
    [[ -e $state/$job.ok ]] && ! older "$state/$job.ok" 1200 && skip "last good run is under 20 h old"
    if ((RESTIC_JOB_SKIP_ON_BATTERY)); then
        on_ac || skip "the battery is discharging (on battery)"
    fi
    if ((RESTIC_JOB_SKIP_METERED)); then
        # The reader is chosen by what the host has; the seam forces nmcli on a host that also has busctl.
        if [[ ${RESTIC_JOB_NM:-} != nmcli ]] && command -v busctl >/dev/null; then
            gate_busctl
        else
            gate_nmcli
        fi
    fi
    exit 0
}

# Keeps the log under 1 MiB by one rotated copy, then points stdout and stderr at the new file. It rotates inside
# the wrapper because the cron line's own redirect would keep writing to the rotated file's inode.
reopen_log() {
    [[ -f $1 && $(stat -c %s "$1") -gt 1048576 ]] && mv -f "$1" "$1.1"
    exec >>"$1" 2>&1
}

# The cron counterpart of restic-job@.service on a host without systemd. Cron starts it as root.
# It holds a lock, runs the gate (a skip is logged, never notified), runs the job under the limits the unit sets
# (no new privileges and only CAP_DAC_READ_SEARCH, as the unit's sandbox does; MemoryMax has no cron
# counterpart), logs the run and sends the notification the notify units send.
cron_job() {
    local self logf rc=0 kind=ok result=success line pid
    PATH=${RESTIC_JOB_PATH:-/usr/sbin:/usr/bin:/sbin:/bin} # test seam: stub directories
    export PATH
    self=$(readlink -f "$0")
    load "$1"
    logf=$logdir/$job.log
    umask 077
    exec 9>"/run/restic-$job.lock"
    # A run still going from the previous hour is not an error.
    flock -n 9 || {
        echo "$(date -Is) restic-job: skipped: the previous run still holds the lock" >>"$logf"
        exit 0
    }
    reopen_log "$logf"
    if ((RESTIC_JOB_SKIP_METERED || RESTIC_JOB_SKIP_ON_BATTERY)); then
        line=$( (gate "$job") 2>&1)
        rc=$?
        if ((rc == 1)); then
            echo "$(date -Is) $line"
            exit 0
        elif ((rc)); then
            echo "$(date -Is) restic-job: gate failed (exit $rc): $line"
            kind=fail result=exit-code
        fi
    fi
    if [[ $kind == ok ]]; then
        echo "$(date -Is) restic-job: start $job"
        # --foreground: the stop signal reaches restic-job alone, which relays SIGINT to restic so that it
        # deletes its lock while ssh is still alive; the unit's KillMode=mixed does the same.
        # setsid gives the chain its own session, so that what survives the final SIGKILL (restic, ssh) can be
        # killed by session below. 9>&- keeps the lock descriptor away from the chain: a straggler must not hold it.
        setsid timeout --foreground --signal=INT --kill-after="$kill_after" "$RESTIC_JOB_TIMEOUT" \
            nice -n 19 ionice -c 3 \
            setpriv --reuid restic --regid restic --init-groups --inh-caps +dac_read_search \
            --ambient-caps +dac_read_search --bounding-set -all,+dac_read_search --no-new-privs \
            "$self" run "$job" 9>&- &
        pid=$!
        trap 'kill -INT "$pid" 2>/dev/null' INT TERM
        while :; do
            wait "$pid"
            rc=$?
            kill -0 "$pid" 2>/dev/null || break
        done
        trap - INT TERM
        pkill -KILL -s "$pid" 2>/dev/null
        echo "$(date -Is) restic-job: exit $rc"
        case $rc in
        0 | 3) ;;
        124 | 137) kind=fail result=timeout ;;
        *) kind=fail result=exit-code ;;
        esac
    fi
    # A failed delivery has no retry here, unlike the notify unit; freshness alerts when the job stays unfinished.
    (MONITOR_EXIT_STATUS=$rc MONITOR_SERVICE_RESULT=$result RESTIC_JOB_LOG=$logf notify "$kind-$job") ||
        echo "$(date -Is) restic-job: the notification was not delivered"
    [[ $kind == ok ]]
}

notify() {
    local kind=${1%%-*} j=${1#*-} title prio=high tags=rotating_light body
    # A skipped run (ExecCondition=) is silent; OnSuccess= still fires for it.
    [[ ${MONITOR_SERVICE_RESULT:-} == exec-condition ]] && return 0
    case $kind:${MONITOR_EXIT_STATUS:-} in
    ok:3) title="restic $j ok with warnings" prio=default tags=warning ;;
    ok:*) title="restic $j ok" prio=low tags=white_check_mark ;;
    # An empty exit status means the job never ran because a dependency such as RequiresMountsFor= failed.
    # systemd reports Result=success for such a job.
    fail:) title="restic $j FAILED: did not start (a required mount or dependency failed)" ;;
    *) title="restic $j FAILED (${MONITOR_SERVICE_RESULT:-unknown}/$MONITOR_EXIT_STATUS)" ;;
    esac
    if [[ -n ${RESTIC_JOB_LOG:-} ]]; then
        body=$(tail -n 8 "$RESTIC_JOB_LOG")
    elif [[ -n ${MONITOR_INVOCATION_ID:-} && -n ${MONITOR_EXIT_STATUS:-} ]]; then
        body=$(journalctl _SYSTEMD_INVOCATION_ID="$MONITOR_INVOCATION_ID" -n 8 -o cat --no-pager 2>&1)
    else
        body=$(systemctl --failed --no-legend --plain 2>&1)
    fi
    NTFY_STRICT=1 /usr/local/bin/ntfy-notify "$(uname -n): $title" "${body:-(no log lines)}" "$prio" "$tags" ||
        exit 1
    [[ $kind == fail ]] && rm -f "$state/$j.interrupted"
    return 0
}

# Alerts go out at most once a day per condition. The stamps live in $alerts, a root-owned directory, because
# the state directory is writable by the job's user and a stamp there could be forged.
alert_due() { [[ ! -e $alerts/$1 ]] || older "$alerts/$1" 1380; }

# Prints "<used %> <minimum free %>" for a <job>.storage marker, or fails. The marker is written by the job's user, so
# root reads only a regular file, at most 32 bytes, and uses nothing that is not two short numbers.
read_marker() {
    local line
    [[ -f $1 && ! -L $1 ]] || return 1
    line=$(timeout 2 head -c 32 "$1" 2>/dev/null) || return 1
    [[ $line =~ ^[0-9]{1,3}\ [0-9]{1,2}$ ]] || return 1
    echo "$line"
}

freshness() {
    local env m j max ref msg='' delivered=0 failed=0 st pct min marker where="See journalctl -u 'restic-job@*'."
    local -a stale=() stopped=()
    [[ -d $alerts ]] || mkdir -m 0700 "$alerts"
    # With the cron redirect on stdout, rotate that log like the job logs.
    if [[ $(readlink /proc/self/fd/1) == "$logdir/freshness.log" ]]; then
        reopen_log "$logdir/freshness.log"
    fi
    for env in "$conf"/*.env; do
        [[ -e $env ]] || continue
        j=$(basename "$env" .env)
        # shellcheck source=/dev/null
        max=$(. "$env" && echo "$RESTIC_JOB_MAX_AGE_HOURS")
        ref=$state/$j.ok
        [[ -e $ref ]] || ref=$env # no good run yet: the clock starts when the env file was last written
        if older "$ref" $((max * 60)); then
            alert_due "stale-$j" && stale+=("$j")
        else
            rm -f "$alerts/stale-$j"
        fi
        [[ -e $state/$j.storage || -L $state/$j.storage ]] || rm -f "$alerts/storage-$j"
    done
    # A marker stays until the weekly check finds enough space again, so the alert repeats daily.
    for st in "$state"/*.storage; do
        [[ -e $st || -L $st ]] || continue
        j=$(basename "$st" .storage)
        marker=$(read_marker "$st") || {
            log "ignoring $st: not a regular file of two short numbers"
            continue
        }
        alert_due "storage-$j" || continue
        read -r pct min <<<"$marker"
        if NTFY_STRICT=1 /usr/local/bin/ntfy-notify "$(uname -n): Storage Box at $pct% used" \
            "Less than $min% is free for restic job $j. Free space on the Storage Box before backups start failing." \
            high rotating_light; then
            touch "$alerts/storage-$j"
            delivered=1
        else
            failed=1
        fi
    done
    for m in "$state"/*.interrupted; do
        [[ -e $m ]] && stopped+=("$(basename "$m" .interrupted)")
    done
    if ((${#stale[@]} + ${#stopped[@]})); then
        [[ -e /etc/cron.d/restic-freshness ]] && where="See $logdir/."
        ((${#stale[@]})) && msg+="No good backup within the limit: ${stale[*]}. "
        ((${#stopped[@]})) && msg+="Stopped mid-run (shutdown or stop): ${stopped[*]}. "
        if NTFY_STRICT=1 /usr/local/bin/ntfy-notify "$(uname -n): restic backups need attention" \
            "$msg$where" high rotating_light; then
            for j in "${stale[@]}"; do touch "$alerts/stale-$j"; done
            for j in "${stopped[@]}"; do rm -f "$state/$j.interrupted"; done
            delivered=1
        else
            failed=1
        fi
    fi
    ((failed)) && exit 1
    exit $((delivered ? 2 : 0))
}

case ${1:-} in
run) run_job "${2:?job}" ;;
exec)
    load "${2:?job}"
    shift 2
    # Root does not stage in the restic-owned tmp directory, and the restic user creates it if it is missing.
    if ((EUID)); then [[ -d $TMPDIR ]] || mkdir -m 0700 "$TMPDIR"; else unset TMPDIR; fi
    exec "${r[@]}" --no-cache "$@"
    ;;
gate) gate "${2:?job}" ;;
storage)
    load "${2:?job}"
    storage_check
    ;;
cron) cron_job "${2:?job}" ;;
notify) notify "${2:?ok-<job> or fail-<job>}" ;;
freshness) freshness ;;
*) die "usage: restic-job run|exec|gate|cron <job> ... | notify ok-<job>|fail-<job> | freshness" ;;
esac
