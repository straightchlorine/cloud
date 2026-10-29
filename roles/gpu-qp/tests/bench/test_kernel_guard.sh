#!/usr/bin/env bash
# kernel-guard.sh (root, systemd timer), `close` and the status line, against stubs: the system paths
# live under $GPU_QP_KG_ROOT, update-grub and runuser are fakes.
#   bash tests/bench/test_kernel_guard.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
setup_tree

B=$T/bench
R=$T/sys
export GPU_QP_KG_ROOT=$R
unset FAKE_MODE FAKE_RELEASE FAKE_PS FAKE_INFO FAKE_STACK FAKE_FAIL_CELL FAKE_SIDE FAKE_KERNEL FAKE_UPDATE_GRUB FAKE_RUNUSER
K111=6.12.111+deb13-cloud-amd64
K113=6.12.113+deb13-cloud-amd64
UUID=4e9f54f3-865c-43fa-9b87-69ad69d4dd9a
WANT="GRUB_DEFAULT=\"gnulinux-advanced-$UUID>gnulinux-$K111-advanced-$UUID\" # gpu-qp kernel pin"

guard() { bash "$LIB/kernel-guard.sh" "$@" 2>&1; }
grub_calls() { grep -c '^update-grub$' "$FAKE_LOG"; }
default_line() { grep '^GRUB_DEFAULT=' "$R/etc/default/grub"; }
has() { [ -e "$1" ] && echo yes || echo no; }
sys_sum() { (cd "$T" && find sys bench/kernel.pin -type f -print0 2> /dev/null | sort -z | xargs -0 sha256sum | sha256sum); }

# the real excerpt of the host's grub.cfg, the two installed kernels
fresh_sys() {
  rm -rf "$R" "$B"/g* "$B/kernel.pin"
  mkdir -p "$R/boot/grub" "$R/etc/default" "$R/etc/apt/apt.conf.d"
  cat > "$R/boot/grub/grub.cfg" << EOF2
submenu 'Advanced options for Debian GNU/Linux' \$menuentry_id_option 'gnulinux-advanced-$UUID' {
	menuentry 'Debian GNU/Linux, with Linux $K113' --class debian --class gnu-linux --class gnu --class os \$menuentry_id_option 'gnulinux-$K113-advanced-$UUID' {
	menuentry 'Debian GNU/Linux, with Linux $K111' --class debian --class gnu-linux --class gnu --class os \$menuentry_id_option 'gnulinux-$K111-advanced-$UUID' {
EOF2
  printf 'GRUB_DEFAULT=0\nGRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX=""\n' > "$R/etc/default/grub"
  for k in $K111 $K113; do : > "$R/boot/vmlinuz-$k"; done
  mkdir -p "$R/lib/modules/$K111/updates/dkms"
  : > "$R/lib/modules/$K111/updates/dkms/nvidia-current.ko.xz"
  : > "$FAKE_LOG"
}

# mkrun NAME VERDICT BORN [HOSTKERNEL]: a managed run of phase S with no cell done
mkrun() {
  local n=$1
  mkdir -p "$B/$n/S"
  cp -a "$LIB" "$B/$n/lib"
  echo S > "$B/$n/phases"
  echo "[supervise] start $3 run=$n phases=S lib=x" > "$B/$n/supervise.log"
  [ -z "$2" ] || echo "$2" > "$B/$n/supervise.done"
  : > "$B/$n/S/state.tsv"
  [ -z "${4:-}" ] || echo "kernel=$4" > "$B/$n/host"
}

# 1. a stopped run is pending: the pin goes on, to the running kernel (the run has no host record)
fresh_sys
mkrun g1 stopped 2026-10-01T00:00:00Z
out=$(guard); rc=$?
check "pin: rc" "$rc" "0"
check "pin: GRUB_DEFAULT exactly the submenu>entry ids" "$(default_line)" "$WANT"
check "pin: other grub lines kept" "$(grep -c '^GRUB_TIMEOUT=5$' "$R/etc/default/grub") $(wc -l < "$R/etc/default/grub")" "1 3"
check "pin: update-grub once" "$(grub_calls)" "1"
check "pin: apt blacklist file" "$(grep -c '^Unattended-Upgrade::Package-Blacklist {$' "$R/etc/apt/apt.conf.d/52gpu-qp-kernel-pin") $(grep -cE '^	"(linux-image-|linux-headers-|\.\*nvidia|libcuda|libnvcuvid)";$' "$R/etc/apt/apt.conf.d/52gpu-qp-kernel-pin")" "1 5"
check "pin: kernel.pin" "$(cat "$B/kernel.pin")" "$K111 g1"
check "pin: logged" "$(grep -c "pinned to $K111 (pending: g1)" <<< "$out")" "1"
check "pin: status line" "$(cli status --run g1 --no-color | grep '^kernel pinned')" "kernel pinned to $K111 (pending: g1)"

# 2. a second pass changes nothing and does not call update-grub
before=$(sys_sum)
out=$(guard)
check "idempotent: nothing changed" "$(sys_sum) $(grub_calls)" "$before 1"
# the reboot picked another kernel: the recorded pin still holds
out=$(FAKE_KERNEL=$K113 guard)
check "sticky: still K111" "$(default_line) $(cut -d' ' -f1 "$B/kernel.pin")" "$WANT $K111"
check "sticky: says to reboot" "$(grep -c 'the pin applies at the next reboot' <<< "$out")" "1"

# 3. the oldest pending run's host record wins; a younger run is listed too
fresh_sys
mkrun g1 stopped 2026-10-01T00:00:00Z "$K111"
mkrun g2 "" 2026-10-02T00:00:00Z "$K113"
out=$(FAKE_KERNEL=$K113 guard)
check "oldest run's kernel: GRUB_DEFAULT" "$(default_line)" "$WANT"
check "oldest run's kernel: both pending" "$(cat "$B/kernel.pin")" "$K111 g1 g2"

# 4. a pinned kernel without an NVIDIA module: an error and no GRUB change
fresh_sys
mkrun g1 stopped 2026-10-01T00:00:00Z "$K113"
before=$(sys_sum)
out=$(guard); rc=$?
check "no module: rc 1" "$rc" "1"
check "no module: message" "$(grep -c "ERROR cannot pin $K113: no NVIDIA DKMS module" <<< "$out")" "1"
check "no module: nothing touched" "$(sys_sum) $(grub_calls) $(default_line)" "$before 0 GRUB_DEFAULT=0"
check "no module: no apt file, no pin" "$(has "$R/etc/apt/apt.conf.d/52gpu-qp-kernel-pin") $(has "$B/kernel.pin")" "no no"
rm -f "$R/boot/vmlinuz-$K113"
mkdir -p "$R/lib/modules/$K113/updates/dkms"
: > "$R/lib/modules/$K113/updates/dkms/nvidia.ko.xz"
out=$(guard); rc=$?
check "no vmlinuz: rc 1 and the message" "$rc $(grep -c "ERROR cannot pin $K113: no /boot/vmlinuz-$K113" <<< "$out")" "1 1"
# the dots and the plus of a release are not regex: this one has no menu entry
rm -f "$B/g1/host"
mkrun g1 stopped 2026-10-01T00:00:00Z "6x12x111+deb13-cloud-amd64"
: > "$R/boot/vmlinuz-6x12x111+deb13-cloud-amd64"
mkdir -p "$R/lib/modules/6x12x111+deb13-cloud-amd64/updates/dkms"
: > "$R/lib/modules/6x12x111+deb13-cloud-amd64/updates/dkms/nvidia.ko"
out=$(guard); rc=$?
check "no menu entry: rc 1 and the message" "$rc $(grep -c 'no menu entry gnulinux-6x12x111+deb13-cloud-amd64-advanced' <<< "$out")" "1 1"
check "no menu entry: grub untouched" "$(default_line) $(grub_calls)" "GRUB_DEFAULT=0 0"
mkrun g1 stopped 2026-10-01T00:00:00Z '6.12.111;rm -rf'
out=$(guard); rc=$?
check "bad kernel string: refused" "$rc $(grep -c 'not a kernel release' <<< "$out")" "1 1"

# 5. everything DONE: the pin comes off; GRUB_DEFAULT goes back to 0
fresh_sys
mkrun g1 stopped 2026-10-01T00:00:00Z
guard > /dev/null
check "setup: pinned" "$(default_line) $(grub_calls)" "$WANT 1"
echo ok > "$B/g1/supervise.done"
out=$(guard); rc=$?
check "unpin: rc" "$rc" "0"
check "unpin: GRUB_DEFAULT=0, update-grub again" "$(default_line) $(grub_calls)" "GRUB_DEFAULT=0 2"
check "unpin: apt file and kernel.pin gone" "$(has "$R/etc/apt/apt.conf.d/52gpu-qp-kernel-pin") $(has "$B/kernel.pin")" "no no"
check "unpin: status shows nothing" "$(cli status --run g1 --no-color | grep -c '^kernel pinned')" "0"
out=$(guard)
check "unpin: idempotent" "$(grub_calls)" "2"
# without the marker the line is not ours
printf 'GRUB_DEFAULT=2\n' > "$R/etc/default/grub"
out=$(guard)
check "unpin: a GRUB_DEFAULT without the marker stays" "$(default_line) $(grub_calls)" "GRUB_DEFAULT=2 2"

# 6. legacy and closed runs are not pending
fresh_sys
mkdir -p "$B/g9/S"
echo S > "$B/g9/phases"
echo stopped > "$B/g9/supervise.done"
: > "$B/g9/S/state.tsv"
mkrun g1 "" 2026-10-01T00:00:00Z
mkrun g2 failed:S 2026-10-02T00:00:00Z
mkrun g3 blocked:disk 2026-10-03T00:00:00Z
check "ignored: legacy, FAILED and BLOCKED runs" "$(cli _pending | cut -f1,2 | tr '\t' ' ' | paste -sd' ' -)" "g1 INCOMPLETE"
check "close: a cut-off run" "$(cli close --run g1)" "closed run g1"
check "close: CLOSED state" "$(cli runs | awk -F'\t' '$1 == "g1" { print $2 }')" "CLOSED"
check "close: again" "$(cli close --run g1 2>&1)" "[FAIL] run g1 is already CLOSED"
check "close: legacy run" "$(cli close --run g9 2>&1)" "[FAIL] legacy run, read-only"
check "close: a closed run is not pending" "$(cli _pending | wc -l)" "0"
out=$(guard)
check "closed and others: no pin" "$(has "$R/etc/apt/apt.conf.d/52gpu-qp-kernel-pin") $(grub_calls) $(default_line)" "no 0 GRUB_DEFAULT=0"
check "close: resume skips it" "$(cli resume --dry-run)" "nothing to resume"
check "close: resume --run refuses" "$(cli resume --run g1 2>&1)" "[FAIL] run g1 is closed"
check "close: start refuses" "$(cli start --run g1 2>&1)" "[FAIL] run g1 is closed; start a new run"
mkrun g4 stopped 2026-10-04T00:00:00Z
echo "$$ 1" > "$B/g5.tmp"; rm -f "$B/g5.tmp"
check "close: a stopped run with cells left is pending until closed" "$(cli _pending | cut -f1 | paste -sd' ' -)" "g4"
cli close --run g4 > /dev/null
check "close: then it is not" "$(cli _pending | wc -l)" "0"

# 7. failures change nothing: a failed query keeps the pin, a failed update-grub puts the file back
fresh_sys
mkrun g1 stopped 2026-10-01T00:00:00Z
guard > /dev/null
before=$(sys_sum)
out=$(FAKE_RUNUSER=fail guard); rc=$?
check "query fails: rc 1, pin kept" "$rc $(sys_sum) $(grub_calls)" "1 $before 1"
fresh_sys
mkrun g1 stopped 2026-10-01T00:00:00Z
cp "$R/etc/default/grub" "$T/grub.before"
out=$(FAKE_UPDATE_GRUB=fail guard); rc=$?
check "update-grub fails: rc 1, file restored" "$rc $(cmp -s "$T/grub.before" "$R/etc/default/grub" && echo same)" "1 same"
check "update-grub fails: no apt file, no pin" "$(has "$R/etc/apt/apt.conf.d/52gpu-qp-kernel-pin") $(has "$B/kernel.pin")" "no no"
check "update-grub fails: the next pass pins" "$(guard > /dev/null; default_line)" "$WANT"

# 8. --unpin (the role turned the guard off) works without a query
check "--unpin: removes it" "$(FAKE_RUNUSER=fail guard --unpin > /dev/null; default_line) $(has "$B/kernel.pin")" "GRUB_DEFAULT=0 no"
check "usage" "$(guard --nope | head -n 1)" "usage: kernel-guard.sh [--unpin]"

finish
