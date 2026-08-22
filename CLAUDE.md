# Claude Code Development Guidelines

Development principles for this Ansible-based infrastructure deployment
system. These are enforced standards -- new code must follow them, and
existing violations should be fixed when encountered.

## Repo Orientation

```
inventory/production/   hosts.yml, group_vars/, host_vars/, vault.yml.example
playbooks/              site.yml (fleet), per-stack plays, dns-teardown.yml
roles/                  common dns os hardware firewall backup backup-system
                        monitoring prometheus-exporters automation music-stack
scripts/                per-role host check scripts (scripts/dns/validate-*.sh)
docs/                   flat topic docs + docs/testing/ section
.woodpecker/            lint.yaml, test.yaml, deploy-validation.yaml
```

### Reference implementation

**`roles/dns` is the refactored reference role.** Role structure, fail-fast
validation, post-deploy validation, teardown, molecule scenarios, and the
host-check scripts there are the current standard. Several older roles
predate the refactor -- when they conflict with dns patterns, follow dns
and treat the old pattern as a refactor target, not a precedent.

**The step-by-step recipe for building or refactoring a role is
`docs/role-recipe.md`** -- start there for any new role or refactor; this
file holds the standards it builds on.

## Core Principles

### 1. No Redundancy

- **Single Source of Truth**: Common functionality must be centralized in shared roles
- **DRY Principle**: Never duplicate code, tasks, or configuration
- **Common Roles**: Use `roles/common/tasks/` for shared functionality (Docker,
  packages, network facts, backup, syncthing, ntfy, etc.)
- **Consolidated Templates**: Reuse templates and configuration patterns across roles
- **Cross-role invocation**: Roles invoke common tasks with role-specific
  variables via `include_role: name=common tasks_from=<task>`

### 2. Fail-Fast Validation

- **No Defaults**: Never use `| default()` for internal configuration -- force explicit configuration
- **Pre-deployment Validation**: Validate all required variables and dependencies before deployment
- **Required Variables**: Use validation tasks to ensure critical variables are set
- **Explicit Configuration**: All configuration must be intentionally set, not assumed
- **Acceptable exceptions**: See "Acceptable Default Patterns" section below

### 3. Generalized Roles

- **Role Abstraction**: Create roles that work across multiple hosts and scenarios
- **Parameterization**: Use variables to make roles flexible and reusable
- **Common Tasks**: Extract common patterns into shared task files
- **Scalable Design**: Design roles to work with 1 host or 100 hosts

### 4. No Hardcoding

- **Dynamic Detection**: Use Ansible facts for system information (IPs, interfaces, architecture)
- **Variable References**: Use variables for all configuration values
- **Network Facts**: Use `primary_interface`, `primary_ip`, `host_ip_cidr`,
  `primary_network_cidr` instead of hardcoded values (set by `common/tasks/network_facts.yml`)
- **Localhost binding is not hardcoding**: `127.0.0.1` in port bindings for
  management interfaces is intentional security, not a hardcoding violation

### 5. Security First

- **Principle of Least Privilege**: Minimal access and permissions
- **Container Isolation**: Use Docker user namespace mapping (`userns-remap: default`)
- **Interface Binding**: Bind management interfaces to localhost only
- **Authentication Required**: No unauthenticated access to management interfaces
- **Checksum Verification**: Verify checksums (SHA256) for all downloaded binaries
- **No curl|bash**: Never use `curl | bash` for installation -- use package managers or verified binary downloads with checksums
- **Scoped sudoers**: NOPASSWD entries must list specific subcommands, never wildcards like `/usr/bin/restic *`
- **Vault for secrets**: All secrets use `vault_` prefixed variables stored in ansible-vault encrypted files

### 6. Resilient Deployments

- **Block/rescue for critical operations**: Wrap destructive or complex steps in `block`/`rescue` with rollback logic
- **No dead handlers**: Every handler must be notified by at least one task. Remove unused handlers.
- **Idempotent operations**: All tasks must be safe to re-run
- **Health checks**: Post-deployment validation for every service

---

## Variable Naming Conventions

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

## Variable Management

```yaml
# [FAIL] Wrong - uses defaults
pihole_interface: "{{ primary_interface | default('eth0') }}"

# [OK] Correct - explicit, will fail if undefined
pihole_interface: "{{ primary_interface }}"
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
    all/all.yml                   # Global: domain, timezone, docker version
    all/backup.yml                # Global: backup user, restic version
    services.yml                  # Service hosts: common systemd, backup, SSD
    prometheus.yml                # Monitored hosts: exporter config
    vault.yml.example             # Template for the vault-encrypted file
  host_vars/
    pi-dns.yml                    # Production DNS host
    pi-dns-test.yml               # Disposable DNS staging/test Pi
    pi-automation.yml             # Automation-specific: traefik, subdomains
    pi-music.yml                  # Music stack host
    debian-monitoring.yml         # Monitoring-specific: grafana, prometheus
    backup_wyse.yml               # Coordinator-specific: backup targets
    station-arch.yml              # Workstation
```

## Acceptable Default Patterns

While `| default()` is banned for internal config, these patterns are acceptable.
Every `| default()` in committed code should be one of these -- if it is not,
it is a bug (`/comment` and `/audit` flag it):

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

## Comments and Documentation Standards

The `name:` field is the documentation; Ansible prints it at runtime. A comment
must earn its place by explaining a constraint the `name:` cannot carry:

- **Explain WHY, not WHAT.** Good: ordering constraints, external-tool quirks,
  idempotency guards, rollback rationale. Bad: restating the task name, the
  module, or the filename.
- **No file-header restatements** (`# DNS role tasks`) -- the path says it.
- **No day-X history notes** ("this used to be X", "moved to Y in commit Z") --
  describe the current truth only.
- **No LLM-directed prose** -- comments are for humans maintaining this repo.
- Every `| default()` must be (or cite) an Acceptable Default Pattern above;
  every `ignore_errors: true` needs a rationale comment.
- Jinja2 templates: comment only non-obvious branching or a value's non-obvious source.
- Molecule sandbox-constraint comments are load-bearing but rot fast -- keep them
  matching current truth.

Run `.claude/commands/comment.md` (`/comment roles/<role>/`) to audit a scope.

Docs live flat in `docs/{topic}.md`. The one nested section is `docs/testing/`
(`index.md` + per-topic pages) -- testing outgrew a single file. Role internals
belong in role comments + `roles/{role}/README.md`, not new docs files.

---

## Docker Compose Patterns

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

### Required Practices

- **Resource limits**: Every container must have memory/CPU limits and
  reservations based on `hardware_limits` (set by the `hardware` role from
  the host's `device_type`)
- **Localhost binding**: Management ports bind to `127.0.0.1`, not `0.0.0.0`
- **User namespace**: Run containers as `{{ ansible_uid }}:{{ ansible_gid }}` where possible
- **Read-only mounts**: Use `:ro` suffix for volumes that don't need writes
- **No latest tags**: Pin container image versions explicitly
- **userns-remap preservation**: When modifying `/etc/docker/daemon.json`,
  always use `combine()` to merge, never overwrite. Verify the `userns-remap`
  key is preserved after writes.

---

## Backup Integration

Wire any new service into the backup system by setting these variables in host_vars:

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

Coordinator-backed hosts (remote targets) are added to `backup_coordinator_targets`
in the coordinator's host_vars instead (see docs/backup/index.md).

---

## Monitoring Integration

1. Add the host to the `prometheus` group in `inventory/production/hosts.yml`
2. Set required variables in host_vars:

```yaml
prometheus_role: "my-service"
device_type: "rpi4b"

# Enable exporters as needed
prometheus_exporters_node_exporter_enabled: true
prometheus_exporters_docker_exporter_enabled: true   # If running Docker
pi_hardware_metrics_enabled: false                   # Only for ARM hosts
prometheus_exporters_pihole_exporter_enabled: false  # Only for DNS hosts
```

3. The `prometheus-exporters` role handles the rest: user creation, binary
   download (with checksum verification), systemd services, firewall rules,
   and health checks.

---

## Testing and CI/CD

The canonical testing documentation is `docs/testing/`:

- `index.md` -- the four-tier model (lint -> molecule -> staging Pi -> scoped
  production), current coverage, CI status, and the bug list that justified
  the test rebuild
- `molecule-standard.md` -- the codified Molecule standard and the step-by-step
  recipe for rebuilding a role's tests (`roles/dns/molecule/` is the reference)
- `beyond-molecule.md` -- the staging-Pi cycle, scoped production, verifier
  alternatives, secrets policy
- `operations.md` -- pre-commit hooks, `validate-infrastructure.yml`, manual
  procedures

### Binding Molecule rules (details in docs/testing/molecule-standard.md)

- **Converge runs the real role** (or its real container-safe task files via
  `include_role: tasks_from`) -- never hand-copied fixtures. Tautological
  converge is why the January 2026 handler-casing regression shipped green.
- **Idempotence is mandatory.** Fix `changed_when`; never exclude a failing
  task. Reasoned `molecule-idempotence-notest` tags are only for tasks a
  container physically cannot converge (e.g. chrony without CAP_SYS_TIME).
- **Fail-fast scenarios include the real `tasks/validate.yml`** per case and
  assert the failure names the exact variable/condition. A rescue accepting any
  failure is a false-positive factory.
- **Converge and verify are separate processes** -- cross-phase results go
  through marker files (`force: false`), not `set_fact`.
- **Verify asserts on role output** (deployed script contents/modes/ownership,
  cron entries), not files converge wrote for the test.
- Templates referenced by included task files require `include_role:
  tasks_from`; raw `include_tasks` paths lose `role_path` context.
- Deploy + teardown in one scenario: `meta: flush_handlers` between phases.

A rebuilt role ships `default`, `fail-fast-validation`, and (when it has a
teardown) a `teardown` scenario. Older roles still carry pre-refactor,
fixture-based scenarios; rebuild before extending them.

### CI (Woodpecker on Codeberg)

1. **lint.yaml** -- every push: ansible-lint, yamllint, shellcheck, syntax checks
2. **test.yaml** -- Molecule under Podman; matrix currently runs only `dns`.
   Re-add each role to `.woodpecker/test.yaml` as its tests are rebuilt.
3. **deploy-validation.yaml** -- pre-production validation on tag/deploy events

- Failures must fail the pipeline -- no `|| true` on molecule steps
- Line length limit: 120 characters (enforced by yamllint)

### Staging host cycle (tier 3)

Containers cannot prove what a real Pi can. Before touching production,
run the staging cycle documented in docs/testing/beyond-molecule.md
(teardown -> validate-clean.sh -> deploy -> validate-deploy.sh) and add a
`scripts/{role}/validate-*.sh` pair for new roles with hardware-coupled
behavior.

---

## Teardown Playbook Pattern

Every teardown playbook (`playbooks/dns-teardown.yml` is the reference):

1. Gate on the role's own confirm flag (`dns_teardown_confirm | default(false)`
   is an acceptable cross-role flag default -- the playbook never loads role
   defaults) and hard-refuse the production host by name and IP.
2. Set a shared `teardown_confirmed: true` fact -- the single gate every
   included teardown task file checks.
3. Include the real teardown task files; nothing may remove state outside a
   confirmed run.
4. End with self-verification: assert artifacts gone and ports free, so a
   partial teardown fails loudly instead of poisoning the next test run.

---

## Adding New Roles

Full recipe: **`docs/role-recipe.md`** -- reusability-first inventory,
directory layout, variable/task conventions, lifecycle files, tests.
Checklist summary:

Checklist for adding a new service role:

1. **Check common roles first** -- does the functionality already exist in
   `roles/common/tasks/`? Reuse it.
2. **Create the role structure:**

   ```
   roles/{new-role}/
     defaults/main.yml      # All configurable variables (no | default() usage)
     handlers/main.yml      # Only handlers that are actually notified
     meta/main.yml          # Role dependencies
     tasks/
       main.yml             # Entry point: validate -> setup -> deploy -> verify
       validate.yml         # Fail-fast variable validation (include common unified_validation)
       post_deploy_validate.yml  # Health checks
     templates/             # Jinja2 templates
     molecule/              # Per docs/testing/molecule-standard.md
   ```

3. **Follow the dns role's main.yml shape**: os/hardware discovery -> network
   facts -> validate.yml -> packages -> service setup (block/rescue where
   destructive) -> optional features -> firewall -> post_deploy_validate.yml
4. **Add to inventory**: host_vars, group membership, firewall ports
5. **Add to playbooks/site.yml** with appropriate tags
6. **Add Molecule scenarios** per docs/testing/molecule-standard.md, then add
   the role to the matrix in `.woodpecker/test.yaml`
7. **Wire backup** via the `restic_backup` common task
8. **Wire monitoring** by adding to the `prometheus` group

### Adding New Hosts

1. Add to `inventory/production/hosts.yml` with appropriate groups
2. Create `host_vars/{hostname}.yml` with all required variables (no defaults)
3. Add to the `prometheus` group for monitoring
4. Add to backup targets (standalone or coordinator)
5. Set `device_type`, `prometheus_role`, and exporter flags

---

## Validation Requirements

Every role validates pre-deployment via `common/tasks/unified_validation.yml`
(see `roles/dns/tasks/validate.yml` for the wiring):

- Required variables defined in host_vars or group_vars
- Vault placeholder detection (refuse deploying with example values)
- Network interface existence, OS/architecture support
- Conditional guards: variables needed only when a feature is enabled
  (`dns_ntp_allowed_networks` non-empty when NTP serving is on)

Post-deployment, `post_deploy_validate.yml` proves service health directly
(endpoints respond, blocking actually works, timers active) rather than
inferring from side effects.

---

## Error Handling

- Use `failed_when` for expected failure conditions
- Use `ignore_errors: true` sparingly and always with a rationale comment
- Implement `block/rescue` for critical deployment steps (e.g. Pi-hole installation)
- Rollback logic in rescue blocks should use `ignore_errors: true` since the
  system may be in an inconsistent state

---

## Maintenance Guidelines

### Refactoring Existing Code

1. Identify redundant patterns across roles; extract to shared roles
2. Remove `| default()` and add explicit validation
3. Replace hardcoded values with dynamic facts
4. Remove dead handlers (not notified by any task)
5. Add `block/rescue` around critical operations that lack rollback
6. Rebuild the molecule scenarios on the dns pattern (docs/testing/molecule-standard.md)

### Version Control

- Commit frequently with descriptive messages
- Tag major changes and refactoring milestones
- Document breaking changes that require configuration updates

---

**Remember**: If you're about to copy-paste code or add a default value, stop
and think about how to make it reusable and explicit instead.
