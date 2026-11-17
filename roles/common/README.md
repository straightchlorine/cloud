# common

Shared task files for every Debian host role. Nothing here runs on its own except `main.yml`
(the fleet base play); roles pull individual files in with
`include_role: name=common tasks_from=<file>` and pass inputs as variables.

`main.yml` applies, in order: packages, fail2ban, timezone, logrotate, ntfy helper and
unattended-upgrades, dotfiles, and the opt-in Wi-Fi power-save, cloud-init switch-off (`common_cloud_init_disabled`)
and zram tuning. Chrony is applied
by the fleet play before it.

Inputs are `common_*` unless the contract predates the prefix (`compose_*`, `validation_*`),
which `roles/monitoring` still consumes.

## Task files

| File | Purpose | Inputs |
|------|---------|--------|
| `packages.yml` | dpkg lock wait, recovery, apt cache, common + role packages | `role_specific_packages` (optional) |
| `package_cache_update.yml` | apt cache refresh honouring the cache age | `common_package_cache_valid_time` |
| `apt_source.yml` | third-party apt repository: key, one-line source, cache refresh | `common_apt_source_name`, `_key_url`, `_key_path`, `_line` |
| `chrony.yml` | NTP client, optional NTP server; `fake-hwclock` on boards without `/dev/rtc0` | `common_ntp_server_enabled`, `common_ntp_allowed_networks`, `common_ntp_upstream_server` |
| `fail2ban.yml` | SSH jail; restarts fail2ban after a failed start | `common_fail2ban_*` |
| `rpi_headless.yml` | removes the display driver overlay, turns off display/camera/audio probing, `gpu_mem=16`; asks for a reboot | `common_rpi_headless_enabled`, `common_rpi_config_txt` |
| `logrotate.yml` | rotates `/var/log/*-syncthing-backup.log`, the logs the repo's cron jobs write | `common_log_rotation_days`, `common_log_compression` |
| `auto_updates.yml` | unattended-upgrades, night window, reboot notification | `common_auto_updates_*` |
| `ntfy_install.yml` | `ntfy-notify` helper and its API key file | `vault_ntfy_api_key` |
| `ntfy_notify.yml` | one notification from a play | `common_ntfy_title`, `_message`, `_priority`, `_tags` |
| `base_reapply.yml` | `ntfy_install` + `auto_updates`, for tag-scoped role runs | - |
| `dotfiles.yml` | shared tmux config | - |
| `network_facts.yml` | `primary_interface`, `primary_ip`, `primary_network_cidr`, `host_ip_cidr` (once per run) | - |
| `docker.yml` | Docker CE from the apt repository, userns-remap, daemon.json, `common_dockremap_uid/gid` | `common_docker_data_root` (fact), `common_rpi_cgroup_memory_enabled` |
| `docker_rpm.yml` | Docker CE on RPM hosts | `common_docker_rpm_*` |
| `rpi_cgroups.yml` | memory cgroup flags in cmdline.txt (Raspberry Pi only) | - |
| `optional_ssd.yml` | mount an unused SSD at the data path, optionally format it (destructive) | `common_ssd_mount_path`, `_format`, `_filesystem`, `_mount_options`, `_journald_enabled` |
| `detect_optional_drive.yml` | find an unused non-boot drive | - |
| `journald_relocate.yml`, `journald_limits.yml` | journald on the SSD, size cap | `common_journald_path`, `common_journald_system_max_use` |
| `wifi_powersave.yml` | boot unit that turns Wi-Fi power save off | `common_wifi_powersave_tuning_enabled` |
| `zram.yml`, `zram_config.yml`, `zram_teardown.yml` | compressed RAM swap; `zram_config` renders `/etc/default/zramswap` only | `common_zram_*` |
| `syncthing.yml` | Syncthing from its apt repository | `common_syncthing_home` |
| `syncthing_share.yml` | install Syncthing once and register folders | `common_syncthing_share_folders` |
| `syncthing_folder.yml` | one folder (used by `syncthing_share`) | `common_syncthing_folder` |
| `syncthing_teardown.yml` | remove Syncthing | - |
| `stack_snapshot_backup.yml` | nightly snapshot script and cron for a stack | `common_snapshot_*` |
| `app_update.yml` | weekly application update cron | `common_app_update_*` |
| `pihole_password_sync.yml` | apply the vault Pi-hole password to an installed Pi-hole | - |
| `build_docker_compose.yml` | render `docker-compose.yml` and `.env`; drops services no longer declared | `compose_*` |
| `deploy_compose_stack.yml` | render, `up -d --remove-orphans`, poll critical services | `compose_*`, `start_stack` |
| `compose_containers_check.yml` | fail if a critical compose service is not running | `compose_file_path`, `compose_owner`, `compose_critical_services` |
| `verify_cadvisor_metrics.yml` | cAdvisor `/metrics` answers | `common_cadvisor_port` |
| `docker_stack_service.yml` | the `stack` systemd unit | `common_stack_description`, `_home`, `_user`, `_environment_vars`, `_restart_sec` |
| `stack_start.yml` | start the unit, flush the `Restart stack` handler | `common_start_stack` |
| `stack_user_ids.yml` | publish `common_stack_uid` / `common_stack_gid` | - |
| `manage_stack_script.yml` | `manage-<name>` script and PATH symlink | `common_manage_stack_home`, `_name` |
| `unified_validation.yml` | required variables, vault placeholders, OS family | `validation_context`, `_type`, `_role`, `required_variables`, `vault_placeholders`, `validation_supported_os_families` |
| `validate_stack_paths.yml` | stack path parents exist, stack home not under /root | `validation_role`, `validation_data_paths`, `validation_stack_home_var` |
| `teardown_guard.yml` | playbook gate: confirm flag, protected hosts, `teardown_confirmed` | `common_teardown_name` |
| `teardown_gate.yml` | role gate: refuse without `teardown_confirmed` | `common_teardown_name` |
| `teardown_stack_service.yml` | remove the stack unit, compose project down | `common_teardown_stack_home`, `_stack_user` |
| `teardown_cron.yml` | remove cron entries, assert gone | `common_teardown_cron_jobs` |
| `teardown_paths.yml` | remove a path list, assert gone | `common_teardown_name`, `common_teardown_paths` |
| `teardown_verify_absent.yml` | assert paths are absent | `common_teardown_name`, `common_teardown_paths` |

## Teardown flag

`teardown_guard.yml` reads `<name>_teardown_confirm` where `<name>` is `common_teardown_name` with
`-` replaced by `_`: `gpu-qp` -> `gpu_qp_teardown_confirm`.

## Handlers

`Restart chrony`, `Restart fail2ban`, `Restart docker`, `Reload systemd`, `Restart apt timers`,
`Restart systemd-journald`, `Restart wifi-powersave`, `Restart zramswap`, `Restart stack`.
A role that notifies one of them must run a common task first so the handlers are loaded.

## Templates

`systemd-service.j2` is the shared unit template. Roles outside common render it with
`src: "{{ role_path }}/../common/templates/systemd-service.j2"`; its inputs are
`service_*`, `exec_*` and the `common_*` hardening switches (see the file header).
`docker-service.yml.j2` renders one compose service from a `compose_services` entry.
