#!/usr/bin/env bash
# Read-only snapshot of the honeypot host's current state, for porting the
# hand-installed infra/centos setup into the honeypot Ansible role.
#
# Run ON THE HONEYPOT as root:  sudo ./collect-host-state.sh > state.txt
#
# Touches nothing: every command is a query. Secrets are masked - env files
# are printed as KEY=<set|empty> only, and the public IPv4/IPv6 of the box is
# replaced with a placeholder so the output is safe to paste.

set -uo pipefail
export LC_ALL=C

hdr() { printf '\n\n===== %s =====\n' "$*"; }
# Callers pass ONE shell-command string (pipes, redirects, && chains and quoted
# args included), so evaluate the string explicitly. Using `eval "$@"` here
# would re-join/re-split the arguments (SC2294) - `eval "$1"` states the
# single-string contract and preserves whitespace and symbols exactly.
run() { printf '\n--- $ %s\n' "$1"; eval "$1" 2>&1 | sed 's/^/  /'; }

# Print an env file's keys without their values.
env_keys() {
    if [ -r "$1" ]; then
        printf '\n--- %s (values masked)\n' "$1"
        sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=\(.*\)$/  \1=/p' "$1" \
            | while read -r k; do printf '%s<set-or-empty>\n' "$k"; done
    else
        printf '\n--- %s: ABSENT or unreadable\n' "$1"
    fi
}

{
hdr "identity"
run "cat /etc/os-release"
run "uname -a"
run "uptime"
run "hostnamectl"

hdr "packages"
run "rpm -q firewalld fail2ban fail2ban-systemd audit dnf-automatic policycoreutils-python-utils checkpolicy rclone age tailscale docker-ce docker-ce-cli containerd.io docker-compose-plugin cronie epel-release"
run "dnf repolist enabled"
run "rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' | grep -E '^(docker|containerd|tailscale|fail2ban|firewalld|audit|rclone|age)' | sort"

hdr "installed-file fingerprints (compare against the repo copies)"
run "sha256sum /etc/ssh/sshd_config.d/99-hardening.conf /etc/firewalld/zones/tailnet.xml /etc/fail2ban/jail.local /etc/dnf/automatic.conf /etc/sysctl.d/99-hardening.conf /etc/audit/rules.d/honeypot.rules /etc/docker/daemon.json /etc/cron.daily/honeywatch-cowrie-cleanup /usr/local/sbin/honeywatch-backup /usr/local/sbin/honeywatch-mmdb-refresh /etc/systemd/system/honeywatch-*.service /etc/systemd/system/honeywatch-*.timer 2>&1"
run "ls -la /etc/ssh/sshd_config.d/ /etc/systemd/system/ | grep -E 'honeywatch|hardening|total|:$'"

hdr "sshd effective config"
run "sshd -T 2>/dev/null | grep -Ei '^(port|listenaddress|addressfamily|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractive|authenticationmethods|allowusers|allowgroups|maxauthtries|maxsessions|maxstartups|logingracetime|clientalive|x11forwarding|allowtcpforwarding|gatewayports|permittunnel|permitopen|usedns|printmotd|loglevel|hostkeyalgorithms|kexalgorithms|ciphers|macs|usepam|strictmodes|permitemptypasswords)'"
run "systemctl is-enabled sshd sshd.socket 2>&1"
run "ss -tlnp | grep -E ':(22|2022)\b'"

hdr "firewalld"
run "firewall-cmd --state"
run "firewall-cmd --get-active-zones"
run "firewall-cmd --get-default-zone"
run "firewall-cmd --zone=public --list-all"
run "firewall-cmd --zone=tailnet --list-all"
run "firewall-cmd --zone=docker --list-all"
run "firewall-cmd --zone=trusted --list-all"
run "firewall-cmd --direct --get-all-rules"
run "firewall-cmd --list-all-policies 2>&1 | head -40"
run "ls -la /etc/firewalld/zones/"

hdr "fail2ban"
run "fail2ban-client status"
run "fail2ban-client status sshd-2022"
run "systemctl is-enabled fail2ban; systemctl is-active fail2ban"

hdr "sysctl (only the keys the hardening file sets)"
run "sysctl kernel.kptr_restrict kernel.dmesg_restrict kernel.unprivileged_bpf_disabled user.max_user_namespaces kernel.kexec_load_disabled kernel.sysrq kernel.yama.ptrace_scope net.core.bpf_jit_harden net.ipv4.tcp_syncookies net.ipv4.tcp_rfc1337 net.ipv4.conf.all.rp_filter net.ipv4.conf.all.accept_source_route net.ipv4.conf.all.accept_redirects net.ipv4.conf.all.send_redirects net.ipv4.conf.all.log_martians net.ipv4.icmp_echo_ignore_broadcasts net.ipv4.icmp_ignore_bogus_error_responses net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.all.forwarding net.ipv6.conf.all.accept_redirects fs.protected_symlinks fs.protected_hardlinks fs.protected_regular fs.protected_fifos net.ipv4.ip_forward 2>&1"
run "ls -la /etc/sysctl.d/"

hdr "auditd"
run "auditctl -s"
run "auditctl -l"
run "systemctl is-active auditd"

hdr "selinux"
run "getenforce"
run "sestatus"
run "semodule -l | grep -i honeywatch"
run "semanage port -l | grep -E '^ssh_port_t'"
run "semanage fcontext -l | grep -i honeywatch"
run "ls -laZ /etc/honeywatch/ 2>&1"
run "ls -dZ /var/lib/docker/volumes/honeywatch_geoip-data/_data 2>&1"
run "ls -Z /var/lib/docker/volumes/honeywatch_geoip-data/_data/ 2>&1"
run "getsebool -a | grep -Ei 'docker|container|nis_enabled|domain_can_mmap'"
run "ausearch -m AVC,USER_AVC,SELINUX_ERR -ts recent 2>&1 | tail -60"
run "ausearch -m AVC -ts today 2>&1 | grep -c denied"

hdr "docker"
run "docker version --format '{{.Server.Version}} api={{.Server.APIVersion}}'"
run "cat /etc/docker/daemon.json"
run "docker info --format 'storage={{.Driver}} cgroup={{.CgroupDriver}} live-restore={{.LiveRestoreEnabled}} logging={{.LoggingDriver}} security={{.SecurityOptions}}'"
run "docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'"
run "docker volume ls"
run "docker network ls"
run "systemctl is-enabled docker; systemctl is-active docker"
run "df -h /var/lib/docker"
run "du -sh /var/lib/docker/volumes/honeywatch_cowrie-state/_data/downloads 2>&1"

hdr "tailscale"
run "tailscale version"
run "tailscale status --peers=false 2>&1 | head -5"
run "ip -brief addr show tailscale0"
run "systemctl is-enabled tailscaled; systemctl is-active tailscaled"

hdr "network interfaces"
run "ip -brief addr"
run "ip route"

hdr "honeywatch units and timers"
run "systemctl list-timers --all --no-pager | grep -Ei 'honeywatch|dnf-automatic|NEXT'"
run "systemctl status honeywatch-backup.timer --no-pager -l | head -20"
run "systemctl status honeywatch-mmdb-refresh.timer --no-pager -l | head -20"
run "systemctl cat honeywatch-backup.service honeywatch-backup.timer honeywatch-mmdb-refresh.service honeywatch-mmdb-refresh.timer 'honeywatch-notify@.service' 2>&1"
run "journalctl -u honeywatch-backup.service -n 30 --no-pager"
run "journalctl -u honeywatch-mmdb-refresh.service -n 40 --no-pager"
run "journalctl -u 'honeywatch-notify@*' -n 20 --no-pager"
run "systemd-analyze security honeywatch-backup.service --no-pager 2>&1 | tail -5"

hdr "installed helper scripts (verbatim - these are the source of truth)"
run "cat /usr/local/sbin/honeywatch-backup"
run "cat /usr/local/sbin/honeywatch-mmdb-refresh"
run "cat /etc/cron.daily/honeywatch-cowrie-cleanup"
run "ls -la /usr/local/sbin/ /usr/local/bin/"

hdr "honeywatch config dir (values masked)"
run "ls -la /etc/honeywatch/"
env_keys /etc/honeywatch/backup.env
env_keys /etc/honeywatch/maxmind.env
env_keys /etc/honeywatch/notify.env
run "test -f /etc/honeywatch/backup.age.pub && echo 'backup.age.pub present, recipients:' && grep -c '^age1' /etc/honeywatch/backup.age.pub"

hdr "dnf-automatic"
run "cat /etc/dnf/automatic.conf"
run "systemctl is-enabled dnf-automatic.timer; systemctl is-active dnf-automatic.timer"
run "journalctl -u dnf-automatic.service -n 20 --no-pager"

hdr "cron"
run "ls -la /etc/cron.daily/"
run "run-parts --test /etc/cron.daily"

hdr "users and access"
run "getent passwd | awk -F: '\$3>=1000 && \$3<65000'"
run "getent group wheel docker"
run "ls -la /etc/sudoers.d/"
run "for u in deploy admin; do echo \"# \$u:\"; ls -la /home/\$u/.ssh/ 2>&1; awk '{print \$1, substr(\$2,1,12) \"...\", \$3}' /home/\$u/.ssh/authorized_keys 2>&1; done"

hdr "app stack checkout"
run "ls -la /opt/honeywatch 2>&1 | head -25"
run "git -C /opt/honeywatch log --oneline -3 2>&1"
run "test -f /opt/honeywatch/.env && sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/  \1=<set>/p' /opt/honeywatch/.env"

hdr "storage"
run "df -hT"
run "lsblk -f"
run "free -h"
} 2>&1 | {
    # Mask the box's own public addresses so the dump is safe to paste.
    pub4=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
           | grep -Ev '^(10\.|127\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' | head -1)
    pub6=$(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
           | grep -Ev '^(fd|fe80)' | head -1)
    filter='s/[A-Za-z0-9_-]\{32,\}/<REDACTED-TOKEN>/g'
    [ -n "${pub4:-}" ] && filter="s|${pub4}|<PUBLIC-IPV4>|g; ${filter}"
    [ -n "${pub6:-}" ] && filter="s|${pub6}|<PUBLIC-IPV6>|g; ${filter}"
    sed "$filter"
}
