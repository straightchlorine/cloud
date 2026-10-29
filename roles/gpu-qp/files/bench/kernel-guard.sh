#!/usr/bin/env bash
# kernel-guard.sh [--unpin] (root; gpu-qp-kernel-guard.service, before every unattended upgrade and hourly)
#
# Keeps the kernel and the NVIDIA stack of the host from changing while benchmark work is pending, and
# only then. Pending = what `cli.sh _pending` lists (run as the bench user): a managed run that is
# running or that `gpu-qp resume` would pick up, with cells left. The risky window is the reboot
# between a stop and the next resume, so STOPPED and INCOMPLETE runs count.
#
# Pending work: the pin kernel is the `kernel` of the oldest pending run's host record, else the one
# bench/kernel.pin already names, else the running kernel. It needs /boot/vmlinuz-K and an NVIDIA DKMS
# module for K, or nothing is touched (rc 1). Then
#   - GRUB_DEFAULT in /etc/default/grub names K's menu entry (ids read from grub.cfg), with a marker
#     comment, and update-grub runs only when that line changed;
#   - /etc/apt/apt.conf.d/52gpu-qp-kernel-pin adds the kernel and driver packages to unattended-upgrades'
#     Package-Blacklist (list options merge across files; each entry is a regex matched at the start of
#     the package name). Manual apt still works;
#   - bench/kernel.pin records "K RUN..." for `gpu-qp status`.
# No pending work (or --unpin): all three are removed, GRUB_DEFAULT back to 0 only when the marker is
# there. A failed query changes nothing. Never reboots. Idempotent. GPU_QP_KG_ROOT prefixes the system
# paths (tests).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
. "$HERE/env.sh"

R=${GPU_QP_KG_ROOT:-}
GRUB_CFG=$R/boot/grub/grub.cfg
GRUB_DEF=$R/etc/default/grub
APT_CONF=$R/etc/apt/apt.conf.d/52gpu-qp-kernel-pin
PIN=$GPU_QP_BENCH_ROOT/kernel.pin
MARK='# gpu-qp kernel pin'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

info() { echo "kernel-guard: $*"; }
err() { echo "kernel-guard: ERROR $*" >&2; }

# set_default LINE: make LINE the one GRUB_DEFAULT line of /etc/default/grub (appended when there is
# none). update-grub runs only when the file changed; if it fails the file is put back, so the next pass
# tries again.
set_default() {
  awk -v l="$1" '/^GRUB_DEFAULT=/ { if (!d) print l; d = 1; next } { print } END { if (!d) print l }' \
    "$GRUB_DEF" > "$TMP/grub" || return 1
  cmp -s "$TMP/grub" "$GRUB_DEF" && return 0
  cp "$GRUB_DEF" "$TMP/grub.orig"
  cat "$TMP/grub" > "$GRUB_DEF"
  if ! update-grub > "$TMP/update-grub.out" 2>&1; then
    cat "$TMP/grub.orig" > "$GRUB_DEF"
    err "update-grub failed, $GRUB_DEF restored: $(tail -n 3 "$TMP/update-grub.out" | paste -sd' ' -)"
    return 1
  fi
  info "$1"
}

unpin() {
  if [ -e "$APT_CONF" ]; then rm -f "$APT_CONF"; info "removed $APT_CONF"; fi
  rm -f "$PIN"
  if grep '^GRUB_DEFAULT=' "$GRUB_DEF" 2> /dev/null | grep -qF "$MARK"; then
    set_default 'GRUB_DEFAULT=0' || return 1
  fi
}

# write_pin_file CONTENT: bench/kernel.pin through a fresh temp file and a rename: the bench user owns the
# directory, so a link planted at the name is replaced, not followed.
write_pin_file() {
  local t
  t=$(mktemp "$PIN.XXXXXX") || return 1
  chmod 0644 "$t"
  echo "$1" > "$t" && mv -fT "$t" "$PIN"
}

# pin KERNEL RUNS
pin() {
  local k=$1 sub uuid entry
  [[ $k =~ ^[0-9A-Za-z.+~_-]+$ ]] || { err "not a kernel release: $k"; return 1; }
  [ -f "$R/boot/vmlinuz-$k" ] || { err "cannot pin $k: no /boot/vmlinuz-$k"; return 1; }
  compgen -G "$R/lib/modules/$k/updates/dkms/nvidia.ko*" > /dev/null \
    || compgen -G "$R/lib/modules/$k/updates/dkms/nvidia-current.ko*" > /dev/null \
    || { err "cannot pin $k: no NVIDIA DKMS module under /lib/modules/$k/updates/dkms"; return 1; }
  # fixed-string matches: the dots and plus signs of the release are not regex
  sub=$(grep -oE "'gnulinux-advanced-[^' ]+'" "$GRUB_CFG" 2> /dev/null | head -n 1 | tr -d "'")
  [ -n "$sub" ] || { err "cannot pin $k: no gnulinux-advanced submenu id in $GRUB_CFG"; return 1; }
  uuid=${sub#gnulinux-advanced-}
  entry=gnulinux-$k-advanced-$uuid
  grep -qF "'$entry'" "$GRUB_CFG" || { err "cannot pin $k: no menu entry $entry in $GRUB_CFG"; return 1; }

  set_default "GRUB_DEFAULT=\"$sub>$entry\" $MARK" || return 1
  cat > "$TMP/apt" << 'EOF2'
// Managed by Ansible (gpu-qp kernel-guard): while a benchmark run has work left, unattended-upgrades must
// not change the kernel or the NVIDIA stack. Adds to the blacklist of 50unattended-upgrades. Each entry is
// a regex matched at the start of the package name. Manual apt is not affected.
Unattended-Upgrade::Package-Blacklist {
	"linux-image-";
	"linux-headers-";
	".*nvidia";
	"libcuda";
	"libnvcuvid";
};
EOF2
  if ! cmp -s "$TMP/apt" "$APT_CONF" 2> /dev/null; then
    install -m 0644 "$TMP/apt" "$APT_CONF" && info "wrote $APT_CONF"
  fi
  echo "$k $2" > "$TMP/pin"
  cmp -s "$TMP/pin" "$PIN" 2> /dev/null || write_pin_file "$k $2" || return 1
  info "pinned to $k (pending: $2)"
  [ "$(uname -r)" = "$k" ] || info "running $(uname -r), the pin applies at the next reboot (never rebooted here)"
}

if [ "${1:-}" = --unpin ]; then unpin; exit $?; fi
[ $# -eq 0 ] || { echo "usage: kernel-guard.sh [--unpin]" >&2; exit 2; }

rows=$(runuser -u "$GPU_QP_USER" -- bash "$HERE/cli.sh" _pending) || { err "could not list the pending runs: nothing changed"; exit 1; }
if [ -z "$rows" ]; then
  unpin
  exit $?
fi

runs=$(cut -f1 <<< "$rows" | paste -sd' ' -)
k=$(awk -F'\t' '$3 != "-" { print $3; exit }' <<< "$rows")
[ -n "$k" ] || read -r k _ < "$PIN" 2> /dev/null
: "${k:=$(uname -r)}"
pin "$k" "$runs" || exit 1
