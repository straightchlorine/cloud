# Claude Code Development Guidelines

This document outlines the development principles and guidelines for maintaining
this Ansible-based infrastructure deployment system. These are enforced standards
-- any new code must follow them, and existing violations should be fixed when
encountered.

## Core Principles

### 1. No Redundancy

- **Single Source of Truth**: Common functionality must be centralized in shared
  roles
- **DRY Principle**: Never duplicate code, tasks, or configuration
- **Common Roles**: Use `roles/common/tasks/` for shared functionality (Docker,
  packages, network facts, backup, etc.)
- **Consolidated Templates**: Reuse templates and configuration patterns across
  roles
- **Cross-role invocation**: Roles invoke common tasks with role-specific
  variables via `include_role: name=common tasks_from=<task>`

### 2. Fail-Fast Validation

- **No Defaults**: Never use `| default()` for internal configuration -- force
  explicit configuration
- **Pre-deployment Validation**: Validate all required variables and dependencies
  before deployment
- **Required Variables**: Use validation tasks to ensure critical variables are set
- **Explicit Configuration**: All configuration must be intentionally set, not
  assumed
- **Acceptable exceptions**: See "Acceptable Default Patterns" section below

### 3. Generalized Roles

- **Role Abstraction**: Create roles that work across multiple hosts and scenarios
- **Parameterization**: Use variables to make roles flexible and reusable
- **Common Tasks**: Extract common patterns into shared task files
- **Scalable Design**: Design roles to work with 1 host or 100 hosts

### 4. No Hardcoding

- **Dynamic Detection**: Use Ansible facts for system information (IPs,
  interfaces, architecture)
- **Variable References**: Use variables for all configuration values
- **Environment Adaptation**: Code should adapt to different environments
  automatically
- **Network Facts**: Use `primary_interface`, `primary_ip`, `host_ip_cidr`,
  `primary_network_cidr` instead of hardcoded values
- **Localhost binding is not hardcoding**: `127.0.0.1` in port bindings for
  management interfaces is intentional security, not a hardcoding violation

### 5. Security First

- **Principle of Least Privilege**: Minimal access and permissions
- **Container Isolation**: Use Docker user namespace mapping (`userns-remap:
  default`)
- **Interface Binding**: Bind management interfaces to localhost only
- **Authentication Required**: No unauthenticated access to management interfaces
- **Checksum Verification**: Verify checksums (SHA256) for all downloaded binaries
- **No curl|bash**: Never use `curl | bash` for installation -- use package
  managers or verified binary downloads with checksums
- **Scoped sudoers**: NOPASSWD entries must list specific subcommands, never
  wildcards like `/usr/bin/restic *`
- **Secure Defaults**: When security options exist, choose the most secure
- **Vault for secrets**: All secrets use `vault_` prefixed variables stored in
  ansible-vault encrypted files

### 6. Resilient Deployments

- **Block/rescue for critical operations**: Wrap destructive or complex deployment
  steps in `block/rescue` with rollback logic
- **No dead handlers**: Every handler must be notified by at least one task.
  Remove unused handlers.
- **Idempotent operations**: All tasks must be safe to re-run
- **Health checks**: Post-deployment validation for every service

---

## Implementation Guidelines

### Variable Management

```yaml
# [FAIL] Wrong - uses defaults
pihole_interface: "{{ primary_interface | default('eth0') }}"

# [OK] Correct - explicit, will fail if undefined
pihole_interface: "{{ primary_interface }}"
```

### Variable Naming Conventions

Follow the `{role}_{descriptive_name}` pattern consistently:

```yaml
# Ports: {role}_{service}_port
automation_traefik_web_port: 80
monitoring_grafana_port: 3000

# Paths: {role}_{purpose}_path or {role}_stack_home
automation_stack_home: "/home/automation/automation-stack"
monitoring_data_path: "/var/lib/monitoring"

# Feature flags: {role}_{feature}_enabled
dns_auto_updates_enabled: true
prometheus_exporters_docker_exporter_enabled: true

# Subdomains: {role}_subdomain_{service}
automation_subdomain_traefik: "traefik"
automation_subdomain_vaultwarden: "vault"

# Vault secrets: vault_{descriptive_name}
vault_domain_name: "example.com"
vault_grafana_admin_password: "..."
vault_restic_automation_password: "..."

# Lists: {role}_{descriptive}_directories or {role}_{descriptive}_list
music_stack_music_library_directories:
  - music
  - downloads
```

### Inventory Variable Hierarchy

Variables are resolved in this priority order (highest wins):

1. **host_vars/{hostname}.yml** -- Host-specific overrides
2. **group_vars/{group}.yml** -- Group-level settings (services, prometheus)
3. **group_vars/all/*.yml** -- Global defaults (all.yml, backup.yml)
4. **roles/{role}/defaults/main.yml** -- Role defaults (lowest priority)

```
inventory/production/
  hosts.yml                       # Host definitions and group membership
  group_vars/
    all/
      all.yml                     # Global: domain, timezone, docker version
      backup.yml                  # Global: backup user, restic version
    services.yml                  # Service hosts: common systemd, backup, SSD
    prometheus.yml                # Monitored hosts: exporter config
  host_vars/
    pi-dns.yml                    # DNS-specific: pihole config, NTP
    pi-automation.yml             # Automation-specific: traefik, subdomains
    debian-monitoring.yml         # Monitoring-specific: grafana, prometheus
    backup_wyse.yml               # Coordinator-specific: backup targets
```

### Role Structure

```yaml
# [FAIL] Wrong - duplicated across roles
- name: Install packages
  apt: name={{ packages }} state=present

# [OK] Correct - use common role
- name: Include common package management
  ansible.builtin.include_role:
    name: common
    tasks_from: packages
  vars:
    role_specific_packages: "{{ automation_specific_packages }}"
```

### Network Configuration

```yaml
# [FAIL] Wrong - hardcoded IP
pihole_ipv4_address: 192.168.20.10/24

# [OK] Correct - dynamic detection
pihole_ipv4_address: "{{ host_ip_cidr }}"

# [FAIL] Wrong - hardcoded subnet
firewall_source: "192.168.20.0/24"

# [OK] Correct - dynamic network CIDR
firewall_source: "{{ primary_network_cidr }}"
```

### Security Configuration

```yaml
# [FAIL] Wrong - exposed interface
traefik_dashboard_port: 8080

# [OK] Correct - localhost only (this 127.0.0.1 is intentional, not hardcoding)
ports: "127.0.0.1:{{ traefik_dashboard_port }}:8080"

# [FAIL] Wrong - curl pipe to bash
- name: Install rclone
  shell: curl https://rclone.org/install.sh | bash

# [OK] Correct - package manager
- name: Install rclone
  ansible.builtin.include_role:
    name: common
    tasks_from: install_rclone

# [FAIL] Wrong - wildcard sudoers
backup ALL=(root) NOPASSWD: /usr/bin/restic *

# [OK] Correct - scoped subcommands
backup ALL=(root) NOPASSWD: /usr/bin/restic backup *, /usr/bin/restic snapshots *

# [FAIL] Wrong - download without verification
- name: Download binary
  get_url:
    url: "https://github.com/.../binary.tar.gz"
    dest: /tmp/binary.tar.gz

# [OK] Correct - checksum verified download
- name: Download binary
  get_url:
    url: "https://github.com/.../binary.tar.gz"
    dest: /tmp/binary.tar.gz
    checksum: "sha256:{{ verified_checksum }}"
```

---

## Acceptable Default Patterns

While `| default()` is banned for internal config, these patterns are acceptable:

### `| default(omit)` for Optional Module Parameters

```yaml
# [OK] - Ansible omit pattern for optional systemd/docker constraints
memory_limit: "{{ item.memory_max | default(omit) }}"
cpu_quota: "{{ item.cpu_quota | default(omit) }}"
```

This tells Ansible to skip the parameter entirely if undefined, which is
different from providing a fallback value.

### `| default()` on External API Responses

```yaml
# [OK] - Protects against unpredictable external data
msg: "{{ api_result.json.errors | default('Unknown error') }}"
version: "{{ traefik_api.json.version | default('Unknown') }}"
```

External APIs may return unexpected structures. These defaults are diagnostic
safety, not configuration defaults.

### `| default()` on Registered Results from Skipped Tasks

```yaml
# [OK] - Skipped tasks don't register results
loop: "{{ template_test_result.results | default([]) }}"
when: not item.failed | default(false)
```

When an Ansible task is skipped (via `when:`), its registered variable may not
exist. These defaults handle that structural reality.

### `| default(false)` on Cross-Role Feature Flags

```yaml
# [OK] - Flag owned by another role whose defaults aren't loaded here
when: common_syncthing_enabled | default(false) | bool
```

Under tag-scoped runs (e.g. `--tags dns`) or standalone playbooks, the play
that applies the owning role can be filtered out entirely, so its
`defaults/main.yml` never loads and the flag is legitimately undefined. The
default must mirror the flag's own default in the owning role -- never invent
a value it wouldn't use.

---

## Docker Compose Patterns

### Using the Common Compose Builder

Roles define services as dictionaries in `defaults/main.yml` and invoke the
common builder:

```yaml
- name: Build Docker Compose file
  ansible.builtin.include_role:
    name: common
    tasks_from: build_docker_compose
  vars:
    compose_file_path: "{{ automation_stack_home }}/docker-compose.yml"
    compose_file_owner: "{{ ansible_user }}"
    compose_file_group: "{{ ansible_user }}"
    stack_name: "automation"
    compose_services: "{{ automation_compose_services }}"
    compose_networks: "{{ automation_compose_networks }}"
    compose_volumes: "{{ automation_compose_volumes }}"
```

### Service Definition Pattern

```yaml
{role}_compose_services:
  {service_name}:
    image: "service:version"
    container_name: "{service_name}"
    restart: "always"
    ports:
      - "127.0.0.1:{{ role_service_port }}:internal_port"
    user: "{{ ansible_uid }}:{{ ansible_gid }}"
    deploy:
      resources:
        limits:
          memory: "{{ hardware_limits.service.memory }}"
          cpus: "{{ hardware_limits.service.cpus }}"
        reservations:
          memory: "{{ hardware_limits.service.memory_reservation }}"
          cpus: "{{ hardware_limits.service.cpus_reservation }}"
    volumes:
      - "{{ data_path }}/service:/data"
    environment:
      - "ENV_VAR={{ variable }}"
    networks:
      - "network-name"
```

### Required Practices

- **Resource limits**: Every container must have memory/CPU limits and
  reservations based on `hardware_limits` (detected by `detect_hardware.yml`)
- **Localhost binding**: Management ports bind to `127.0.0.1`, not `0.0.0.0`
- **User namespace**: Run containers as `{{ ansible_uid }}:{{ ansible_gid }}`
  where possible
- **Read-only mounts**: Use `:ro` suffix for volumes that don't need writes
  (e.g., Docker socket, music library)
- **No latest tags**: Pin container image versions explicitly
- **userns-remap preservation**: When modifying `/etc/docker/daemon.json`,
  always use `combine()` to merge, never overwrite. Verify `userns-remap` key
  is preserved after writes.

---

## Backup Integration

### Adding Backup to a New Service

Wire any new service into the backup system by setting these variables in
host_vars:

```yaml
# Required
backup_service_name: "my-service"
restic_repository: "sftp:hetzner-storage:{{ vault_backup_repository_base }}/my-service"
restic_password: "{{ vault_restic_my_service_password }}"
backup_paths:
  - "{{ my_service_stack_home }}"
  - "{{ my_service_data_path }}"

# Optional
backup_schedule: "*-*-* 02:00:00"
backup_exclude_patterns:
  - "*.tmp"
  - "**/logs/*"
restic_memory_limit: "1G"
```

Then include the backup task in your role:

```yaml
- name: Configure backup
  ansible.builtin.include_role:
    name: common
    tasks_from: restic_backup
  vars:
    common_backup_service_name: "{{ backup_service_name }}"
    common_backup_paths: "{{ backup_paths }}"
```

This creates: password file, backup script, init script, systemd service+timer.

### Coordinator Backup (for remote hosts)

Add targets to `backup_coordinator_targets` in the coordinator's host_vars:

```yaml
- service_name: "my-service"
  target_host: "my-host"
  ssh_user: "{{ backup_user }}"
  backup_paths:
    - /opt/my-service
  restic_repository: "sftp:hetzner-storage:{{ vault_backup_repository_base }}/my-service"
  restic_password: "{{ vault_restic_my_service_password }}"
  retention_policy:
    daily: 14
    weekly: 8
    monthly: 12
    yearly: 3
  backup_enabled: true
```

---

## Monitoring Integration

### Adding a New Host to Monitoring

1. Add the host to the `prometheus` group in `inventory/production/hosts.yml`
2. Set required variables in host_vars:

```yaml
prometheus_role: "my-service"
device_type: "rpi4b"

# Enable exporters as needed
prometheus_exporters_node_exporter_enabled: true
prometheus_exporters_docker_exporter_enabled: true   # If running Docker
pi_hardware_metrics_enabled: false                   # Only for ARM hosts
prometheus_exporters_pihole_exporter_enabled: false   # Only for DNS hosts
```

3. The `prometheus-exporters` role handles the rest: user creation, binary
   download (with checksum verification), systemd services, firewall rules,
   and health checks.

### Adding Scrape Targets to Prometheus

Add entries to the monitoring role's prometheus configuration in the monitoring
host_vars or the `monitoring/templates/prometheus.yml.j2` template.

---

## Testing and CI/CD

### Molecule Test Structure

Every role must have at least two Molecule scenarios:

```
roles/{role}/molecule/
  default/
    molecule.yml    # Standard test
    converge.yml    # Playbook that applies the role
    verify.yml      # Assertions that verify correct behavior
  fail-fast-validation/
    molecule.yml    # Tests that validation catches missing vars
    converge.yml
    verify.yml
```

### Molecule Configuration

All molecule.yml files use env vars for platform flexibility:

```yaml
---
driver:
  name: podman

platforms:
  - name: test
    image: ${MOLECULE_IMAGE:-docker.io/geerlingguy/docker-debian12-ansible:latest}
    command: ${MOLECULE_COMMAND:-/lib/systemd/systemd}
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:ro

provisioner:
  name: ansible

verifier:
  name: ansible
```

### Verification Best Practices

```yaml
# Use getent to verify users
- name: Check user exists
  ansible.builtin.getent:
    database: passwd
    key: "{{ service_user }}"

# Use stat to verify files/directories
- name: Check config exists
  ansible.builtin.stat:
    path: "{{ config_path }}"

# Use assert with descriptive messages
- name: Assert service is configured
  ansible.builtin.assert:
    that:
      - config_stat.stat.exists
      - config_stat.stat.mode == '0644'
    success_msg: "[OK] Config exists with correct permissions"
    fail_msg: "Config missing or wrong permissions"
```

### CI/CD Pipeline (Woodpecker)

Three pipelines:

1. **lint.yaml** -- Fast feedback on every push: ansible-lint, yamllint,
   shellcheck, markdownlint
2. **test.yaml** -- Molecule with Podman (vfs storage driver in CI), running
   only the roles whose tests are rebuilt on the dns reference pattern
   (currently `dns`; re-add roles to the matrix as their tests are rebuilt -
   see docs/testing-best-practices.md)
3. **deploy-validation.yaml** -- Pre-production: comprehensive molecule tests
   and infrastructure validation on tag/deploy events

### CI Requirements

- Molecule tests must pass without `|| true` -- failures must fail the pipeline
- Platform matrix must actually test different platforms via `MOLECULE_IMAGE`
  env var
- Line length limit: 120 characters (enforced by yamllint)

---

## Adding New Roles

Checklist for adding a new service role:

1. **Check common roles first** -- Does functionality already exist in
   `roles/common/tasks/`? Reuse it.
2. **Create role structure:**

   ```
   roles/{new-role}/
     defaults/main.yml      # All configurable variables (no | default() usage)
     handlers/main.yml      # Only handlers that are actually notified
     meta/main.yml          # Role dependencies
     tasks/
       main.yml             # Entry point: validate -> setup -> deploy -> verify
       validate.yml         # Fail-fast variable validation
       stack.yml            # Service deployment (if Docker-based)
       storage.yml           # Directory/mount setup
       post_deploy_validate.yml  # Health checks
     templates/             # Jinja2 templates
     molecule/
       default/             # Standard test scenario
       fail-fast-validation/ # Validation test scenario
   ```

3. **Follow the service role pattern** in `tasks/main.yml`:

   ```yaml
   - name: Include validation
     ansible.builtin.include_tasks: validate.yml

   - name: Gather network facts
     ansible.builtin.include_role:
       name: common
       tasks_from: network_facts

   - name: Include common packages
     ansible.builtin.include_role:
       name: common
       tasks_from: packages

   - name: Include service setup
     ansible.builtin.include_tasks: stack.yml

   - name: Configure firewall
     ansible.builtin.include_role:
       name: firewall

   - name: Configure backup
     ansible.builtin.include_role:
       name: common
       tasks_from: restic_backup

   - name: Post-deployment validation
     ansible.builtin.include_tasks: post_deploy_validate.yml
   ```

4. **Add to inventory:** host_vars, group membership, firewall ports
5. **Add to playbooks/site.yml** with appropriate tags
6. **Add Molecule tests** with both default and fail-fast-validation scenarios
7. **Add to CI matrix** in `.woodpecker/test.yaml`
8. **Wire backup** via `restic_backup` common task
9. **Wire monitoring** by adding to the `prometheus` group

### Adding New Hosts

1. Add to `inventory/production/hosts.yml` with appropriate groups
2. Create `host_vars/{hostname}.yml` with all required variables
3. Add to `prometheus` group for monitoring
4. Add to backup targets (standalone or coordinator)
5. Set `device_type`, `prometheus_role`, and exporter flags

---

## Validation Requirements

### Pre-deployment Checks

- All required variables must be defined in host_vars or group_vars
- Network connectivity and interface availability
- Required directories and permissions
- Service dependencies (Docker running, etc.)
- Vault placeholder detection (prevent deploying with example values)

### Validation Task Pattern

```yaml
- name: Validate required variables
  ansible.builtin.fail:
    msg: "{{ item }} must be defined"
  when: vars[item] is not defined
  loop:
    - vault_domain_name
    - vault_letsencrypt_email
    - backup_service_name
```

### Conditional Validation

For variables only needed when a feature is enabled:

```yaml
- name: Validate pihole hostname when exporter enabled
  ansible.builtin.fail:
    msg: "pihole_hostname must be defined when pihole_exporter is enabled"
  when:
    - pihole_exporter_enabled
    - pihole_hostname is not defined
```

---

## Role Organization

### Common Role Structure

```
roles/common/
  tasks/
    detect_hardware.yml         # Pi model detection, resource limits
    docker.yml                  # Docker with user namespaces
    network_facts.yml           # Network discovery (primary_ip, primary_network_cidr)
    packages.yml                # Package management
    build_docker_compose.yml    # Standardized compose file generation
    docker_stack_service.yml    # Systemd service for Docker stacks
    restic_backup.yml           # Per-service backup setup
    install_rclone.yml          # Safe rclone installation (via apt)
    unified_validation.yml      # Shared validation framework
    service_verification.yml    # HTTP health check utility
  templates/
    systemd-service.j2
    logrotate.conf.j2
    backup-script.sh.j2
  defaults/main.yml
  handlers/main.yml
```

### Service Role Pattern

```yaml
- name: Include validation
  include_tasks: validate.yml

- name: Gather network facts
  include_role: name=common tasks_from=network_facts

- name: Include common packages
  include_role: name=common tasks_from=packages

- name: Include service-specific setup
  include_tasks: service.yml

- name: Configure firewall
  include_role: name=firewall
```

---

## Documentation Standards

### Code Comments

- No inline comments unless explaining complex logic
- Self-documenting variable names and task descriptions
- README files for complex roles only when absolutely necessary

### Configuration Comments

```yaml
# [OK] Good - explains the why
# Docker user namespace mapping for container isolation
userns-remap: default

# [FAIL] Bad - explains the what (obvious)
# Set the domain name
domain_name: "{{ vault_domain_name }}"
```

---

## Error Handling

- Use `failed_when` for expected failure conditions
- Use `ignore_errors: true` sparingly and with explicit reasoning in a comment
- Implement `block/rescue` for critical deployment steps (e.g., Pi-hole
  installation, database migrations)
- Rollback logic in rescue blocks should use `ignore_errors: true` since the
  system may be in an inconsistent state

---

## Maintenance Guidelines

### Adding New Features

1. Check if functionality already exists in common roles
2. If similar functionality exists, generalize it instead of duplicating
3. Add validation for any new required variables
4. Test with minimal configuration (no defaults)
5. Add Molecule tests covering both success and validation-failure paths

### Refactoring Existing Code

1. Identify redundant patterns across roles
2. Extract common functionality to shared roles
3. Remove `| default()` and add explicit validation
4. Replace hardcoded values with dynamic facts
5. Remove dead handlers (not notified by any task)
6. Add `block/rescue` around critical operations that lack rollback

### Version Control

- Commit frequently with descriptive messages
- Tag major changes and refactoring milestones
- Document breaking changes that require configuration updates
- Line length limit: 120 characters (enforced by yamllint)

---

**Remember**: If you're about to copy-paste code or add a default value,
stop and think about how to make it reusable and explicit instead.
