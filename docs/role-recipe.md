# Role Recipe

The recipe for building or refactoring a role on the `roles/dns` reference
pattern. Follow it top to bottom for a new role or a refactor; the Molecule
details live in [testing/molecule-standard.md](testing/molecule-standard.md)
and are only summarized here.

## 1. Reusability first (the notifications test)

Before writing any role code, inventory what it needs and ask for each
piece: **could another setup use this?**

- **Check `roles/common/tasks/` first.** Packages, network facts,
  validation, Docker/compose building, systemd stack services,
  syncthing (+ teardown), ntfy install/notify, optional-drive
  detection, auto-updates - all exist (off-site backup is
  `roles/restic tasks_from: job`). Invoke, don't reimplement:

  ```yaml
  - name: Send a deployment notification
    ansible.builtin.include_role:
      name: common
      tasks_from: ntfy_notify
    vars:
      common_ntfy_title: "Deployed: {{ inventory_hostname }}"
      common_ntfy_message: "Pi-hole is up."
  ```

- **Anything with cross-role potential becomes a common task file in the
  same change** - not inline role code. The test: if a second role would
  copy-paste it, it moves to `common`. The dns role implements zero
  notification logic itself; it consumes `ntfy_install`/`ntfy_notify`
  and re-applies the fleet helpers through `common/tasks/base_reapply.yml`
  (a `--tags dns` redeploy skips the fleet play that installs them).

- **Common task contract:** parameterized exclusively through `common_*`
  variables passed via `include_role: vars:`; no role names hardcoded;
  safe to include multiple times; idempotent.

- **Role-specific glue stays in the role.** The generic engine goes to
  common; the wiring and policy stay home (e.g. the restic engine is
  `roles/restic`; *what* to back up and *when* is the stack role's `restic_job`).

## 2. Directory structure is the documentation

Files should be few, lean, and named so the tree explains the role's
shape without opening them:

```
roles/{role}/
  defaults/main.yml        # every tunable; nothing else
  handlers/main.yml        # only handlers actually notified
  meta/main.yml
  tasks/
    main.yml               # orchestrator: ordered includes + the one core block
    validate.yml           # fail-fast variable/config validation
    <concern>.yml          # one file per side concern
    post_deploy_validate.yml
    teardown.yml           # only if the role owns removable state
  templates/               # .j2 named after their destination
  files/
  README.md                # only what the tree cannot say
  molecule/                # per testing/molecule-standard.md
```

- `main.yml` reads like a table of contents: os/hardware discovery ->
  network facts -> `validate.yml` -> packages -> core deploy block
  (block/rescue) -> side concerns as includes -> firewall ->
  `post_deploy_validate.yml`. Side concerns (time sync, storage, update
  scripts, backup, notification re-application) each get their own file -
  dns keeps `storage.yml`, `install.yml`, `configure.yml`, `auto_updates.yml`,
  `backup.yml` (a local Teleporter snapshot shared through Syncthing; an
  off-site pull is planned) and `teardown.yml` out of `main.yml`.
- One concern = one file = one reason to touch it. If a file needs a
  table of contents of its own, split it.
- Host-check scripts live in `scripts/{role}/` at the repo root (see
  `scripts/dns/validate-clean.sh` / `validate-deploy.sh`), not inside the
  role - they run on the controller against deployed hosts.

## 3. Variables

- `{role}_{descriptive_name}` always; flags end in `_enabled`; secrets
  are `vault_*` and never appear in defaults.
- **No `| default()` for internal configuration.** Every default in
  committed code must be one of the four Acceptable Default Patterns in
  `CLAUDE.md` (omit for optional module params, external API responses,
  skipped-task results, cross-role flags under tag-scoped runs).
- Consuming another role's flag: `common_x_enabled | default(false) | bool`
  with a comment citing that pattern - under `--tags {role}` the fleet
  play never loads common's defaults.

## 4. Task conventions

- FQCN everywhere (`ansible.builtin.*`).
- `name:` is the documentation; comments only for constraints a name
  cannot carry (ordering, external-tool quirks, idempotency guards) -
  see the comment standards in `CLAUDE.md` and run `/comment` on the
  role before finishing.
- Accurate `changed_when`/`failed_when`; `creates:`/`removes:` guards for
  one-shot commands; `ignore_errors: true` only with a rationale comment.
- Destructive or multi-step deploys go in `block:`/`rescue:` with real
  rollback (dns's Pi-hole install block is the reference: preserve ->
  clean -> install -> verify -> rescue restores).
- Tags match how `site.yml` invokes the role; validation stays runnable
  standalone (`--tags validation`).

## 5. Validation and lifecycle

- `validate.yml`: wire `common/tasks/unified_validation.yml` for required
  vars + vault-placeholder detection, then add role-specific guards
  (interface exists, feature-dependent vars present). It must work when
  included directly by pre-validation, not only via `main.yml`.
- `post_deploy_validate.yml`: prove real behavior (endpoints answer, the
  ad domain is actually blocked, the timer is active) - never infer
  health from a side effect.
- `teardown.yml` (stateful roles): the mirror image of deploy, gated by
  the playbook pattern (`<role>_teardown_confirm` + shared
  `teardown_confirmed` fact + refuse `teardown_protected` hosts, all from
  `common/tasks/teardown_guard.yml`), built from the `common/tasks/teardown_*`
  helpers (gate, cron, stack service, verify-absent), and ends with
  self-verification that fails loudly on leftovers. Restore what the
  deploy disabled (dns restores the resolver and timesync).

## 6. Tests and CI

- Add `roles/{role}/.env.yml` with `MOLECULE_ROLE` (see the shared
  configuration in [testing/molecule-standard.md](testing/molecule-standard.md)).
- Molecule scenarios per the standard: `default`, `fail-fast-validation`
  (real `validate.yml` per case, asserting the exact failure reason), and
  `teardown` when the role has one. Converge runs the real container-safe
  task files; deliberately-excluded parts are listed with reasons.
- Hardware-coupled roles add the staging cycle:
  `playbooks/{role}-teardown.yml` -> `scripts/{role}/validate-clean.sh` ->
  deploy -> `scripts/{role}/validate-deploy.sh`.
- Only when all scenarios are green: add the role to the matrix in
  `.woodpecker/test.yaml`.

## Definition of done

- [ ] Reusable pieces extracted to common (notifications test passed)
- [ ] `main.yml` is a thin orchestrator; one file per concern
- [ ] No `| default()` outside the documented patterns; no hardcoded
      IPs/interfaces; `{role}_` prefixes everywhere
- [ ] `validate.yml` + `post_deploy_validate.yml` prove real behavior
- [ ] Teardown exists for removable state and self-verifies
- [ ] `/comment` audit clean; `just lint` clean
- [ ] All molecule scenarios green; role added to the CI matrix
- [ ] README covers only what the tree cannot say
