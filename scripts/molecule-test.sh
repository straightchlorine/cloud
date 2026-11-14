#!/usr/bin/env bash
# Runs a role's Molecule scenarios: locally all at once, one log each; in CI one after another, live.
# usage: molecule-test.sh <role> [scenario]
#        molecule-test.sh --iterate <role> <scenario>   converge + verify on the live container
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd) || exit 2
molecule=$root/.venv/bin/molecule
[ -x "$molecule" ] || molecule=molecule
conf=$root/.config/molecule
logs=$root/.molecule/logs

die() { echo "error: $*" >&2; exit 2; }

iterate=0
if [ "${1:-}" = --iterate ]; then iterate=1; shift; fi
role=${1:-}
only=${2:-}
[ -n "$role" ] || die "usage: $0 [--iterate] <role> [scenario]"
[ "$iterate" = 0 ] || [ -n "$only" ] || die "--iterate needs a scenario"
cd "$root/roles/$role/molecule" 2>/dev/null || die "no roles/$role/molecule"

# A legacy provisioner.env, .playbooks or .config_options would replace the base config's ansible.* keys.
legacy=$(awk '/^[a-z]/ { top = $1 } top == "provisioner:" && /^  (env|playbooks|config_options):/ { print FILENAME; nextfile }' ./*/molecule.yml)
[ -z "$legacy" ] || die "use ansible.env/.playbooks/.cfg, not provisioner.*: $legacy"

# A scenario is a directory with a molecule.yml.
scenarios=()
for f in */molecule.yml; do [ -f "$f" ] && scenarios+=("${f%/molecule.yml}"); done
[ ${#scenarios[@]} -gt 0 ] || die "no scenarios in roles/$role/molecule"
if [ -n "$only" ]; then
    [ -f "$only/molecule.yml" ] || die "no scenario $role/$only"
    scenarios=("$only")
fi
cd "$root/roles/$role" || exit 2

# The base config is passed explicitly: Molecule does not find it from a git worktree (.git is a file there).
run() { # <scenario> <molecule subcommand>
    local c=(-c "$conf/config.yml")
    [ "$1" = fail-fast-validation ] && c+=(-c "$conf/fail-fast.yml")
    "$molecule" "${c[@]}" "$2" --scenario-name "$1"
}

if [ "$iterate" = 1 ]; then
    run "$only" converge && run "$only" verify
    exit
fi

# One scenario, or CI: one after another with live output; CI honors ci-skip.
if [ -n "$only" ] || [ -n "${CI:-}" ]; then
    failed=()
    for s in "${scenarios[@]}"; do
        if [ -n "${CI:-}" ] && [ -f "molecule/$s/ci-skip" ]; then
            echo "skip $role/$s: $(cat "molecule/$s/ci-skip")"
            continue
        fi
        echo "run  $role/$s"
        SECONDS=0
        run "$s" test || failed+=("$s")
        echo "done $role/$s ${SECONDS}s"
    done
    [ ${#failed[@]} -eq 0 ] || { echo "FAIL $role: ${failed[*]}"; exit 1; }
    exit 0
fi

mkdir -p "$logs"
echo "run  $role: ${scenarios[*]} (logs in .molecule/logs/)"
for s in "${scenarios[@]}"; do
    (
        SECONDS=0
        run "$s" test >"$logs/$role-$s.log" 2>&1
        echo "$? $SECONDS" >"$logs/$role-$s.rc"
    ) &
done
wait
rc=0
for s in "${scenarios[@]}"; do
    read -r code secs <"$logs/$role-$s.rc" || code=1
    if [ "$code" = 0 ]; then
        printf 'ok   %-40s %5ss\n' "$role/$s" "$secs"
    else
        printf 'FAIL %-40s %5ss  .molecule/logs/%s-%s.log\n' "$role/$s" "$secs" "$role" "$s"
        rc=1
    fi
done
exit $rc
