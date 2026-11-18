# Testing

How testing works in this repository. The `dns` role and its Molecule
scenarios are the reference implementation; the roles in the coverage table
below follow the same pattern.

## The four-tier model

1. **Lint** (`ansible-lint`, `yamllint`, `shellcheck`, `markdownlint`, playbook
   syntax checks) - seconds, every push. Catches casing/deprecation/style
   issues before anything executes.
2. **Molecule/container** - role logic, templates, validation, idempotence.
   Fast, disposable, but blind to anything a container fakes. Standard:
   [molecule-standard.md](molecule-standard.md).
3. **Staging host** (the spare Pi, `pi-test-media`) - the real integration
   tier. Actually runs the compose stack on real hardware, actually binds
   service ports, actually proves the role converges on a real Pi. See
   [beyond-molecule.md](beyond-molecule.md).
4. **Production, scoped** - `--limit` to a single host, `--check` first,
   then apply. For infra this size (a handful of Pis, not a fleet),
   canary/blue-green rollout is over-engineering - `--limit` plus a working
   staging tier gets equivalent safety at a fraction of the complexity.

## Coverage by role

A role's scenario set is complete when it has `default`,
`fail-fast-validation` (if it has a `tasks/validate.yml`) and `teardown` (if it
has a `tasks/teardown.yml`), the shape the
[standard](molecule-standard.md) asks for. The table checks that shape and the
CI matrix in `.woodpecker/test.yaml`; it does not judge assertion quality.

| Role | Scenarios | In CI | Set |
| --- | --- | --- | --- |
| dns | default, fail-fast-validation, teardown | yes | complete (reference) |
| automation | default, fail-fast-validation, teardown | yes | complete |
| media | default, fail-fast-validation, teardown | yes | complete |
| gpu-qp | default, fail-fast-validation, teardown | yes | complete |
| restic | default, cron, fail-fast-validation, teardown | yes | complete |
| honeypot | default, fail-fast-validation | yes | complete |
| honeybench | default, fail-fast-validation | yes | no `teardown` scenario |
| prometheus-exporters | default, fail-fast-validation, pihole-exporter | yes | complete |
| common | default, network-facts, board-tuning, docker-installation, ntfy-notify, fail-fast-validation | yes | complete; the `teardown_*` helpers run through the stack roles' teardown scenarios |
| firewall | fail-fast-validation | yes | no `default` |
| os, hardware | default | yes | complete (no `validate.yml`) |
| alloy | none | no | untested |
| monitoring | none | no | untested |
| backup | none | no | retired; only `tasks/teardown.yml` is left |

## What each scenario proves

| Scenario | What it proves |
| --- | --- |
| dns `default` | Real `validate.yml`, `chrony`, `auto_updates.yml` and `backup.yml` run in order; the Pi-hole setup vars template renders; verified: script contents/modes/ownership, cron entries, logrotate, chrony enablement |
| dns `fail-fast-validation` | 5 cases (missing interface, vault placeholder, NTP guard, interface guard, missing backup directory) drive the **real** `validate.yml` - zero hand-copied guards |
| dns `teardown` | Deploy-then-teardown with real task files + real teardown; verifies nothing survives, cron gone, chrony purged, host still resolves, no 53/80 listeners |
| automation `default` | Real `validate.yml` + `stack.yml` (compose + `.env` + manage script) + `backup.yml` run in order; verified: compose services/bindings/no-inlined-secrets, `.env` 0600 with secrets, cron, backup script, systemd unit render; restic is disabled here (`automation_restic_enabled: false`), `roles/restic` covers the engine; validation runs once more with it on, so the job dict this role builds passes the engine's checks |
| automation `fail-fast-validation` | 9 cases (missing var, vault placeholder, TRUSTED_PROXIES catch-all, stack home under /root, cron token, APP_KEY, and three restic cases: no repository, dumps off, a job failing the engine's checks) drive the **real** `validate.yml` |
| automation `teardown` | Deploy-then-teardown with real task files + real teardown; verifies no role artifact survives, cron gone, unit inactive |
| media `default` | Real `validate.yml` + `stack.yml` + `backup.yml` + `youtube.yml` run in order (pipeline on a stub yt-dlp); verified: compose services/bindings/no-inlined-secrets, secretless `.env` 0600, beets config + adopt overlay, yt-dlp rules, snapshot script, cron, one ntfy per sync run; restic is disabled here (`media_restic_enabled: false`), `roles/restic` covers the engine; validation runs once more with it on, so the job dict this role builds passes the engine's checks |
| media `fail-fast-validation` | 5 cases (missing var, stack home under /root, placeholder playlist, restic on without a repository, a short restic password) drive the **real** `validate.yml` |
| media `teardown` | Deploy-then-teardown with real task files + real teardown; verifies no role artifact survives, cron gone, unit inactive |
| prometheus-exporters `default` | Real `common_setup.yml`, the Pi hardware collector run as its unit does (one ext4 error series per filesystem), the real pihole-exporter teardown with its gate satisfied |
| prometheus-exporters `fail-fast-validation` | 9 cases, each asserting the failure names its own missing variable |
| prometheus-exporters `pihole-exporter` | The exporter unit's lifecycle on a stub binary (the download needs a real Pi-hole) |
| common `default` / `network-facts` / `board-tuning` / `fail-fast-validation` | Real `network_facts`, `wifi_powersave` and `unified_validation` task files; idempotent second run |
| common `docker-installation` | Real `docker.yml` twice (root, then a non-root user): dockerd starts with `userns-remap` in a privileged rootless container (test-only: a `dockremap` range inside the container's id map, no iptables or bridge); `daemon.json` keeps the remap key, compose works |
| common `ntfy-notify` | Real `ntfy_install` against a stub HTTP server: only a 2xx is delivery under `NTFY_STRICT`, the bearer token and body arrive verbatim, a missing key is a no-op or exit 1 under strict |
| os `default` / hardware `default` | Real discovery roles, run end to end and checked for idempotence |
| firewall `fail-fast-validation` | The real firewall validation, each refusal asserting its own message |
| gpu-qp `default` / `fail-fast-validation` / `teardown` | Real role, real `validate.yml` per case, deploy-then-teardown (`roles/gpu-qp/molecule/`) |
| honeypot `default` | Real `docker.yml` (common `docker_rpm`, merge mode), `notify.yml`, `backup.yml`, `mmdb_refresh.yml` and `timer_job.yml` on the Rocky 9 image |
| honeypot `fail-fast-validation` | Real `validate.yml` on the Rocky 9 image |
| honeybench `default` | Real `docker.yml` (common `docker_rpm`, overwrite mode) on the Rocky 9 image |
| honeybench `fail-fast-validation` | Real `validate.yml` on the Rocky 9 image |
| restic `default`: engine | Real role through both entry points (`main.yml` and `tasks_from: job`) with the real units under the real sandbox; verified: capability read of a root-only file, excludes applied, forget down to 1 snapshot, writes denied with `CapEff` = `0x4`, the refusal to initialise a missing repository, the Storage Box ssh config and pinned host key. Needs rootful podman |
| restic `default`: failure paths | Exit 3 mapped to success plus a warning ntfy, a missing source and a stale `fresh` path each failing with a FAILED ntfy, a SIGINT stop leaving no lock and its marker cleared on delivery, a failing prune ending the run with a FAILED ntfy, the unlock retry and exit-code paths |
| restic `default`: freshness and prune | The freshness alert for an aged stamp and for an undelivered interruption (exit 2, no restart), the weekly prune and check, once-a-day alert stamps, the hostile-marker cases of the freshness run |
| restic `default`: gates | The metered gate against a stub `busctl` (metered 1/3, a listed unicode/quoted name, no active connection, a metered second link, all unmetered running end to end), the battery gate against fake `power_supply` trees (USB-C charger, Discharging, Full, no battery), the docker-bridge-only case |
| restic `default`: files and migration | The legacy migration including the `backup: true` copies, the lockout guard that keeps `/etc/sudoers.d/backup-user` while the connection user `backup` has no general grant, an unrelated `/opt/backup` left alone, a symlink at the cache directory that is never followed, a non-default `restic_cache_dir` (RequiresMountsFor, ReadWritePaths, TMPDIR in the env file, the default directory never created) |
| restic `fail-fast-validation` | Cases drive the **real** `validate.yml`, `validate_job.yml` and `validate_key.yml`, each asserting its own message (sources incl. quotes, backslashes and trailing newlines, local and sftp repository, password, timeout, host, excludes, duplicate names, ntfy placeholder, wrong-host key pin, Storage Box host/user/port, metered-gate and battery fields, `cron_schedule` syntax and ranges, the scheduler and service-manager check, `restic_cache_dir`) |
| restic `cron` | The real role with `restic_scheduler: cron` on the Debian image (a stand-in for OpenRC: the cron.d, wrapper, setpriv and log paths are real, the init script is not): cron files parsed by the real cron daemon, the wrapper run for real (snapshot, log, ntfy, `CapEff`/`CapBnd` = `0x4` with no new privileges, the lock skip, log rotation, a 2 s timeout that leaves no lock), the gate against canned `nmcli` replies plus the real `nmcli`, battery and throttle skips logged silently, the log-directory freshness hint and the cron teardown. OpenRC itself and cronie stay untested |
| restic `teardown` | Deploys, refuses an unconfirmed teardown, then tears down; verifies the repository and a `root:root 0400` key remain and the unit-listing check passes on an empty result |

The staging-Pi cycle (for example `automation-teardown.yml` ->
`scripts/automation/validate-clean.sh` -> `site.yml --tags automation` ->
`scripts/automation/validate-deploy.sh`) covers what containers cannot; see
[beyond-molecule.md](beyond-molecule.md).

## Rules from past failures

Each rule exists because the opposite shipped a bug that CI did not see.

1. **A task file no converge includes has never run.** Every task file a role
   ships is driven by some scenario's real `include_role`, so an undefined
   variable or a dead gate fails in CI, not on a live host. A converge that
   copies four `template` tasks instead of running the role let a
   handler-casing regression (`61d81a8`, January 2026) reach every role
   with green CI.
2. **A teardown or fail-fast scenario must be able to fail.** A teardown
   include gated on `teardown_confirmed` that converge never sets is
   vacuous; a fail-fast scenario without assertions, or a rescue that accepts
   any failure, passes whatever the role does. Assert the exact message.
3. **Converge and verify do not share facts.** `set_fact` stops at the
   process boundary; pass results through marker files.
4. **Template paths need `include_role: tasks_from`.** A raw `include_tasks`
   path loses `role_path` and the template `src` stops resolving.
5. **Script deployment is one `template` task.** Render-to-staging,
   install-coreutils, remove-staging reports phantom `changed` tasks on every
   run; the module already places files atomically with owner and mode.
6. **Bound every wait on an external daemon.** `chronyc waitsync` against an
   unreachable daemon spins unbounded; wrap it in `timeout`.
7. **A flag that can arrive as a string needs `| bool`.** `-e start_stack=false`
   is the string `"false"`, which bare `when:` treats as true. Test the guard
   with the string value, not only a real boolean.
8. **Assert where a key lands, not only that it exists.** `StartLimitBurst`
   under `[Service]` is ignored by some systemd versions, so the throttling
   was never applied. Render the template and check the section.
9. **Flush handlers before checking the live service.** A `notify:` fires at
   the end of the play, so a `Verify ... is responding` task in the same task
   file runs against the old config. Use `meta: flush_handlers`, and have a
   converge change a value mid-run and assert the live service reflects it.

Known Molecule blind spots, covered only by the staging-Pi cycle
([beyond-molecule.md](beyond-molecule.md)), which stays mandatory before
production however green Molecule is:

- Directory ownership under `userns-remap` (mariadb, Calibre-Web, Vaultwarden,
  Firefly's upload directory): it depends on a container's runtime uid
  mapping, and Molecule containers do not run Docker-in-Docker with the remap.
- Flaky hardware (USB/power-delivery instability, `xhci_hcd ... Host System
  Error`) and DHCP lease changes that strand a container port binding on a
  stale IP. A post-deploy check that the bound address equals `primary_ip` is
  planned, not implemented.

## CI (Woodpecker on Codeberg)

- `lint.yaml` - every push and pull request: ansible-lint, yamllint,
  markdownlint, shellcheck, syntax checks of every playbook. Fast feedback, no
  matrix. The Ansible tools install from the pinned `requirements.txt`, the
  same as `just setup`.
- `test.yaml` - Molecule under Podman, one matrix step per role; the role
  list in `.woodpecker/test.yaml` is the source of truth. Each step installs
  `requirements-test.txt` and runs `scripts/molecule-test.sh <role>`, which
  runs every scenario and honours `ci-skip`. Images and privileges come from
  each role's `.env.yml` (Debian 13 by default, Rocky 9 for honeypot and
  honeybench, privileged for restic). Running scenarios locally:
  [molecule-standard.md](molecule-standard.md#running-scenarios).

## Pages

- [molecule-standard.md](molecule-standard.md) - the codified Molecule
  standard: converge runs the real role, idempotence, shared config and
  helpers, the runner, the rebuild recipe.
- [beyond-molecule.md](beyond-molecule.md) - why Molecule alone is not
  enough: staging Pi, scoped production, verifier alternatives, secrets.
- [operations.md](operations.md) - git hooks, the host-check scripts, adding
  tests.
