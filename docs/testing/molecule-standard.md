# Molecule Testing: The Standard

The codified Molecule standard for this repo. For what to layer on top of / instead of Molecule see
[beyond-molecule.md](beyond-molecule.md); for operational tooling see
[operations.md](operations.md).

## The core rule: converge must run the real role

Molecule's `converge.yml` exists to apply the role under test, not to
reimplement a sample of it. The standard pattern is:

```yaml
- name: Converge
  hosts: all
  roles:
    - role: dns
```

or, if per-scenario vars are needed:

```yaml
- name: Converge
  hosts: all
  tasks:
    - name: Include the dns role
      ansible.builtin.include_role:
        name: dns
```

**Why this matters:** every other test layer (idempotence, verify) is only
as trustworthy as converge. If converge doesn't run `tasks/main.yml`, a
regression in the real deploy path (a renamed handler, a broken `when:`, a
missing task) is invisible to CI. This is a named anti-pattern -
"tautological testing" - where the test mirrors a hand-picked subset of the
implementation instead of exercising it, so the test can never fail for the
reason it exists.

**Reference:** `roles/dns/molecule/default/converge.yml` runs the role's
real container-testable task files (`validate.yml`, then `auto_updates.yml`
and `backup.yml` plus common's `chrony` through `shared/deploy.yml`) via
`include_role: tasks_from`, in the order `main.yml` runs them, and renders
the Pi-hole setup vars template - with a comment listing what is
deliberately NOT included and why (the Pi-hole installer, `storage.yml`,
post-deploy validation, firewall). The `fail-fast-validation` scenario
includes the real `tasks/validate.yml` in every case.

## Idempotence is a separate, mandatory check

The repo's `test_sequence` is:

```
destroy -> syntax -> create -> prepare -> converge -> idempotence ->
verify -> destroy
```

The base config sets this sequence (Molecule's default also runs
dependency, cleanup and side_effect, which the repo has no playbooks for).

`idempotence` re-runs converge and fails if any task reports `changed` the
second time. This is Ansible's own core promise - running a playbook once
should be indistinguishable from running it ten times - and it's the
cheapest test in the sequence to add, since it costs nothing beyond a second
converge pass.

Common causes of idempotence failures, worth knowing before debugging one:

- `command`/`shell` tasks without an accurate `changed_when`
- Templates embedding a live timestamp (e.g. `ansible_date_time.iso8601`)
- Handlers that mutate state further on every run instead of converging

Fail-fast scenarios are the one exception: `scripts/molecule-test.sh` adds
`.config/molecule/fail-fast.yml`, a `test_sequence` without `idempotence`,
to every scenario named `fail-fast-validation`. Their cases only run
`validate.yml` and record markers with `force: false`, so a second converge
proves nothing; the `default` scenario's pass covers the role. A fail-fast
scenario that starts deploying real state loses the exemption.

Do not silence a failing idempotence check by excluding the task - fix the
`changed_when`, or if the operation is genuinely one-shot (e.g. a Pi-hole
first-install script), isolate it behind a real guard (`creates:`, a stat
check) rather than letting it flap.

A task a container physically cannot converge (the chrony service needs
CAP_SYS_TIME; journald restarts whenever anything logs) carries a
`molecule-idempotence-notest` tag with the reason beside it. Deploy a script
with one `template` task: the module already places files atomically with
owner, group and mode, so a render-to-staging dance only adds phantom
`changed` results.

## Lint lives outside Molecule

Molecule no longer ships a `lint` step, so linting is its own pipeline
(`.woodpecker/lint.yaml`; `just lint` locally; see [index.md](index.md)).

## Container vs. VM driver choice

Docker/Podman containers are fast and fine for role logic, templating, and
validation. Switch to a VM driver (or a real disposable host) only when the
thing under test needs systemd unit ordering, kernel parameters, or real
network binding that a container fakes - this repo documents that constraint
for Pi-hole's `basic-install.sh`, which cannot run in a container at all.
Don't reach for a VM driver by default; reach for it when a specific
container limitation is blocking a specific assertion.

## Shared configuration

Molecule merges `.config/molecule/config.yml` into every scenario; the
scenario wins. Dicts merge and lists replace, so a scenario that lists
`platforms` replaces the shared one. The base config holds the podman
driver, the one platform (`<role>-<scenario>`, Debian 13, systemd), the
`test_sequence` above, and `ansible.env`: `ANSIBLE_ROLES_PATH`,
`MOLECULE_SHARED`, `ANSIBLE_INJECT_FACT_VARS=False` (facts only as
`ansible_facts.<name>`), pipelining and the `profile_tasks` summary (each
phase ends with its 20 slowest tasks).

- `roles/<role>/.env.yml` sets `MOLECULE_ROLE` and, where needed,
  `MOLECULE_IMAGE` (Rocky 9 for honeypot and honeybench) or
  `MOLECULE_PRIVILEGED` (restic). Molecule reads it from the role directory
  when it renders `molecule.yml`. A scenario that needs more (the common
  `docker-installation` scenario is privileged with `SYS_ADMIN`) lists its own
  `platforms`.
- A scenario's `molecule.yml` holds only its differences; most are `---`.
  Use `ansible.*` keys (`ansible.env`, `ansible.playbooks`): a legacy
  `provisioner.env`, `.playbooks` or `.config_options` would replace the
  shared `ansible.*` keys instead of merging, so the runner refuses them.
  `provisioner.inventory` is fine.
- Molecule writes its own `ansible.cfg`; settings in the repo's
  `ansible.cfg` never reach a scenario.

## Shared test helpers

`.config/molecule/shared/` holds the task files several roles include, as
`"{{ lookup('env', 'MOLECULE_SHARED') }}/<file>.yml"`. Role-wide test data
lives in `roles/<role>/molecule/shared/` (no `molecule.yml`, so it is not a
scenario).

| File | Input | Does |
| --- | --- | --- |
| `stub_docker.yml` | - | Stub `docker` binary and `docker.service`; each start is counted in `/var/tmp/docker-stub-starts` |
| `assert_failure.yml` | `molecule_case: {id, expect}` | In a rescue: passes only when a failure message starts with `expect`, then writes `/tmp/molecule-case-<id>.passed` |
| `assert_markers.yml` | `molecule_case_ids` | In verify: fails on a missing or extra case marker |
| `assert_paths.yml` | `molecule_paths: [{path, state, mode?, owner?, group?}]` | One stat loop and one labelled assert |

A fail-fast scenario keeps its cases in `fail-fast-validation/cases.yml`
(`molecule_cases`, optional `molecule_case_defaults`), loaded by converge and
verify. `case.yml` runs the real validate file through `include_role:
tasks_from` with a literal `vars:` mapping, fails with a sentinel if
validation passes, and includes `assert_failure.yml` in its rescue. Verify
includes `assert_markers.yml`. Refusal checks in teardown scenarios use the
same pair.

## Running scenarios

`scripts/molecule-test.sh` is the one runner; `just test`, `just iterate`,
the pre-push hook and CI call it.

```bash
just test                     # every role in turn
just test dns                 # all dns scenarios at once, logs in .molecule/logs/
just test dns teardown        # one scenario, live output
just iterate dns teardown     # converge + verify on the live container
```

Locally a role's scenarios run in parallel; in CI (`CI` set) they run one
after another and a `ci-skip` file skips a scenario the runner cannot host.
The runner passes the base config explicitly, because Molecule does not find
it from a git worktree. Platform names keep different scenarios apart; the
same scenario still runs one at a time.

## The rebuild recipe

The work order for building or refactoring a role's tests (the dns role
follows it):

1. `converge.yml`: run the role's real container-testable task files via
   `include_role: tasks_from` (not hand-copied `template` tasks), in the
   order `main.yml` runs them. Skip only the genuinely
   container-incompatible steps, and list them + why in a comment.
2. `verify.yml`: assert against the role's real output paths - deployed
   script contents/modes/ownership, cron entries, service enablement -
   not files converge wrote for the test.
3. `fail-fast-validation`: one case per refusal in `cases.yml`, each
   running the real `roles/<role>/tasks/validate.yml` and asserting the
   failure names the exact variable/condition through `assert_failure.yml`
   (a rescue that accepts *any* failure is a false-positive factory).
4. Add a teardown scenario when the role has a teardown: deploy the real
   container-safe parts, fixture the installer artifacts, run the real
   teardown with its gate satisfied, then verify nothing survives and the
   host still resolves.
5. Discover container-varying facts (the primary interface name) instead of
   hardcoding them - validate.yml checks them for real.
6. Converge and verify run as **separate ansible-playbook processes**:
   `set_fact` in converge is invisible to verify. Record cross-phase results
   as marker files (`/tmp/molecule-<case>.passed`, `force: false` to stay
   idempotent) and stat them in verify.
7. Use `include_role: tasks_from`, not raw `include_tasks` paths, whenever
   the included file references templates - `include_tasks` loses the
   `role_path` context and template srcs stop resolving. Raw paths remain
   fine for task-only files driven with per-case `vars:` (the dns
   fail-fast pattern).
8. When a scenario combines a deploy and a teardown in one converge play,
   `meta: flush_handlers` between them - on real hosts they are separate
   playbook runs, and a handler left pending would fire after the teardown
   removed its service.

## Sources

- [How to Write Idempotence Tests in Molecule](https://oneuptime.com/blog/post/2026-02-21-idempotence-tests-molecule/view)
- [Testing Ansible Roles with Check Mode, ansible-lint, and Molecule](https://oneuptime.com/blog/post/2026-07-24-testing-ansible-roles/view)
- [Test Ansible Roles with Molecule (2026) - ComputingForGeeks](https://computingforgeeks.com/ansible-molecule-testing/)
- [How to Use ansible-lint with Molecule](https://oneuptime.com/blog/post/2026-02-21-how-to-use-ansible-lint-with-molecule/view)
- [Molecule Configuration docs](https://docs.ansible.com/projects/molecule/configuration/)
- [Software Testing Anti-patterns - Codepipes Blog](https://blog.codepipes.com/testing/software-testing-antipatterns.html)
