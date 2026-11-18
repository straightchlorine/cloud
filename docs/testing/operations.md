# Testing Operations

Git hooks, the host-check scripts, and manual procedures. For the
Molecule standard see [molecule-standard.md](molecule-standard.md); for the
staging/production tiers see [beyond-molecule.md](beyond-molecule.md).

## Git hooks

`just setup` installs both. `.pre-commit-config.yaml` runs on commit:
playbook syntax (`just syntax`), an ASCII-only check on CI and test tooling,
yamllint, shellcheck, YAML/JSON validity, large-file, merge-conflict and
private-key detection, markdownlint and whitespace hygiene. `.pre-push-config.yaml` runs on push:
`just lint` (ansible-lint, yamllint) and `just test common default` as the
smoke test.

```bash
pre-commit run --all-files
pre-commit run --hook-stage pre-push --all-files -c .pre-push-config.yaml
```

## Validation

Validation lives in the roles, not in a repo-root playbook: each role ships
`tasks/validate.yml` (pre-deploy) and `post_deploy_validate.yml`
(post-deploy). The `dns` role is the reference for both; the wiring is in
[role-recipe.md](../role-recipe.md#5-validation-and-lifecycle).

## Manual Procedures

The scripted host checks run on the controller against a deployed host
(`scripts/lib/host-check.sh` is the shared helper). Each role's
`validate-clean.sh` follows its teardown playbook; `validate-deploy.sh` follows
a deploy.

```bash
./scripts/dns/validate-clean.sh <host>      # also: automation, media, gpu-qp, restic
./scripts/dns/validate-deploy.sh <host>
```

`roles/dns/README.md` ("Teardown & Re-test") lists what the dns pair checks.
The full cycle around them is in [beyond-molecule.md](beyond-molecule.md).

### Media and automation spot checks

```bash
curl -I http://192.168.20.15:4545/              # Navidrome on the media host
curl http://192.168.20.20:8081/alive            # Vaultwarden health
curl -I http://192.168.20.20:8082/              # Firefly III; 302 to login is healthy
```

The scripted checks are `./scripts/media/validate-deploy.sh <host>` and
`./scripts/automation/validate-deploy.sh <host>`; the spare Pi
(`pi-test-media`) stages the media role, so point the automation script at your
own automation test box.

### Backup

Check a host's engine with `./scripts/restic/validate-deploy.sh <host>`.
Inspect snapshots and restore with `restic-job exec <job> snapshots|restore`;
the procedure is in [docs/backup/restore.md](../backup/restore.md). The
engine's own tests are the restic scenarios in [index.md](index.md).

### Monitoring

The monitoring role is experimental and never deployed; there is no
validation procedure for it yet (see
[docs/monitoring/index.md](../monitoring/index.md)).

## Adding Tests

- **Validation tasks:** extend the role's `tasks/validate.yml` through
  `common/tasks/unified_validation.yml` (`required_variables`,
  `vault_placeholders`) and add one fail-fast case per new refusal.
- **Health checks:** add a task to `post_deploy_validate.yml` that proves the
  behavior directly (an `ansible.builtin.uri` against the endpoint with
  `retries` and `delay`), not a side effect.
- **Molecule scenarios:** follow the rebuild recipe in
  [molecule-standard.md](molecule-standard.md) - converge runs the real task
  files, verify asserts on role output, fail-fast includes the real
  `validate.yml`. New roles enter the Woodpecker matrix only once their tests
  follow that pattern.
