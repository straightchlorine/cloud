# shellcheck shell=bash disable=SC2034
# Shared by every scripts/<role>/validate-{clean,deploy}.sh. The caller sends this file to the
# host ahead of its own body (`{ cat "$LIB"; cat <<'EOF' ... EOF; } | <remote bash -s>`), so
# everything here runs on the host as the unprivileged login user.
set -u
fail=0
pass=0
# Prefix for reads of root-only paths; need_sudo fills it, so the same helpers serve both cases.
HC_SUDO=()

note_ok() {
  echo "[OK]   $1"
  pass=$((pass + 1))
}

note_left() {
  echo "[FAIL] $1"
  fail=$((fail + 1))
}

# Stop at once rather than report every root-only file as missing.
need_sudo() {
  if ! sudo -n true 2>/dev/null; then
    echo "[FAIL] passwordless sudo (sudo -n) is unavailable for $(id -un): cannot read root-only paths"
    exit 1
  fi
  HC_SUDO=(sudo -n)
}

# -L as well: a dangling symlink still counts as left over.
check_absent() {
  if "${HC_SUDO[@]}" test -e "$1" || "${HC_SUDO[@]}" test -L "$1"; then
    note_left "$1 still exists"
  else
    note_ok "$1 absent"
  fi
}

check_present() {
  if "${HC_SUDO[@]}" test -e "$1"; then
    note_ok "$1 present"
  else
    note_left "$1 missing"
  fi
}

# check_script <path> [expected-mode] - the script exists, has an executable bit and, when
# expected-mode is given, exactly that octal mode. Compares stat %a rather than testing [ -x ]
# because a 0700 root script fails -x for other users. -L: a symlink's own mode is always
# lrwxrwxrwx, the real permission lives on its target.
check_script() {
  local path="$1"
  local want_mode="${2:-}"
  local got_mode
  if ! "${HC_SUDO[@]}" test -e "$path"; then
    note_left "$path missing"
    return
  fi
  got_mode="$("${HC_SUDO[@]}" stat -L -c '%a' "$path" 2>/dev/null || echo "000")"
  if [ $((8#$got_mode & 0111)) -ne 0 ] 2>/dev/null; then
    note_ok "$path present + executable"
  else
    note_left "$path not executable (mode: $got_mode)"
    return
  fi
  if [ -n "$want_mode" ]; then
    if [ "$got_mode" = "$want_mode" ]; then
      note_ok "$path mode $want_mode"
    else
      note_left "$path mode is $got_mode (expected $want_mode)"
    fi
  fi
}

# check_mode <path> <mode> <owner:group>
check_mode() {
  local got
  if ! got="$("${HC_SUDO[@]}" stat -c '%a %U:%G' "$1" 2>/dev/null)"; then
    note_left "$1 missing"
  elif [ "$got" = "$2 $3" ]; then
    note_ok "$1 is $2 $3"
  else
    note_left "$1 is $got (want $2 $3)"
  fi
}

# summary_deploy <closing sentence when everything passed>
summary_deploy() {
  echo
  echo "== Summary: $pass passed, $fail failed =="
  if [ "$fail" -gt 0 ]; then
    echo "DEPLOYMENT CHECKS FAILED - inspect the [FAIL] lines above."
    exit 1
  fi
  echo "$1"
}

# summary_clean <closing sentence when nothing was left over>
summary_clean() {
  echo
  echo "== Summary: $pass passed, $fail failed =="
  if [ "$fail" -gt 0 ]; then
    echo "LEFTOVERS FOUND - inspect the [FAIL] lines above."
    exit 1
  fi
  echo "$1"
}
