# Beyond Molecule: Staging, Production, and Alternatives

Molecule (standard per [molecule-standard.md](molecule-standard.md)) covers
role logic on a disposable container. It cannot prove a role works on real
hardware, and it isn't meant to - that's a separate, necessary tier.

## Why Molecule alone is not enough

Ansible's own testing philosophy is explicit about this: don't try to unit
test a declarative playbook, and don't expect infra-level tests to replace
staging/production validation. The stated workflow is dev (embedded tests)
-> staging (integration tests against a prod-like environment) -> production
(the same tests, now as a safety net). A container can fake a lot, but it
cannot fake:

- Pi-hole's `basic-install.sh`, which needs a real init system and touches
  real DNS/DHCP ports - documented as untestable in a container in the DNS
  role.
- Real network topology (VLANs, the actual `primary_network_cidr` a Pi
  sits on).
- Hardware-specific facts (`device_type`, ARM binary architecture checks in
  `prometheus-exporters`).
- Config drift caused by a human SSHing in and hand-editing a file: a
  disposable container has no history to drift from.

This repo already has the right shape for the next tier: a spare Pi
(`pi-test-media`) dedicated to staging the media role before touching the
production `media` host, plus guarded teardown playbooks for tearing that
staging state back down. That's the real integration tier - Molecule should
never be asked to substitute for it. Roles with hardware-coupled behavior
ship a `scripts/<role>/validate-clean.sh` / `validate-deploy.sh` pair
(dns, automation, media, gpu-qp, restic).

## The staging-Pi cycle

The same four-step cycle drives every role that owns removable state; shown
here for the media role (the spare Pi's current assignment - move the host
into another inventory group and swap the playbook/scripts to re-run the
identical cycle for the dns or automation role):

```bash
# 1. Tear down the previous test state
ansible-playbook -i inventory/production playbooks/media-teardown.yml \
  --limit pi-test-media -e media_teardown_confirm=true

# 2. Prove the box is clean
./scripts/media/validate-clean.sh pi-test-media

# 3. Deploy for real
ansible-playbook -i inventory/production playbooks/site.yml \
  --limit pi-test-media --tags media --ask-vault-pass

# 4. Prove the deployment is healthy end-to-end
./scripts/media/validate-deploy.sh pi-test-media
```

Each teardown playbook refuses to run without its confirmation flag
(`media_teardown_confirm=true`, `automation_teardown_confirm=true`,
`dns_teardown_confirm=true`, `gpu_qp_teardown_confirm=true`,
`honeybench_teardown_confirm=true`, `restic_teardown_confirm=true`) and refuses
any host whose host_vars set `teardown_protected: true` (`dns`, `media`,
`pi-automation`, `centos-honeypot`, `station-arch`, `portable`). Flip the flag
to `false` for a staging cycle on a protected host, then set it back.

## Production, scoped

`--limit` to a single host, `--check` first where the module supports it,
then apply. Canary/rolling deployment patterns (serial execution,
health-gated batches) are the right answer once host count makes "test on
staging then deploy to all of prod at once" too risky - not needed at
current scale.

## Alternatives to Molecule itself

If Molecule ever stops fitting (unlikely at this repo's scale, but worth
knowing):

| Tool | What it is | When it beats Molecule |
|---|---|---|
| **Testinfra** (pytest-based) | Python assertions against live server state; historically bundled as a Molecule verifier | Verify logic needs real branching/loops beyond what `ansible.builtin.assert` comfortably expresses |
| **Goss** | Declarative YAML server-state checks | Simple present/absent/running checks, faster to write than Testinfra for the common case - but "switch to Testinfra on the first complication" is the common practitioner take, since Testinfra covers everything Goss does plus more |
| **Serverspec** | RSpec-based (Ruby) | Legacy choice; Testinfra is its Python-era successor. Not worth adopting fresh into an all-Python/Ansible stack |
| **Test Kitchen** (`kitchen-ansible`) | Chef-ecosystem tool, pluggable backends | Only relevant if already in a Chef/Test Kitchen shop; no reason to introduce it here |

Molecule's default verifier is Ansible itself (`ansible.builtin.assert`,
`ansible.builtin.stat`, `ansible.builtin.uri`) - this repo's Molecule setup
already follows that path, and there's no reason to add Testinfra/Goss on
top unless a specific verify.yml assertion becomes awkward to express in
Ansible directly.

## Secrets in the test pipeline

Molecule scenarios pass fake vault values directly as converge vars
(`vault_pihole_webpassword: molecule-test-password`). That's correct for CI
- tests should never touch real vault-encrypted secrets, and whatever
secret store production uses (vault files today, anything else tomorrow)
should keep that boundary: real secrets to staging/production runs, inline
fake values in molecule, and `fail-fast-validation`'s placeholder-detection
case stays what actually proves a real secret was never accidentally left
at its documented default.

## Sources

- [Ansible Testing Strategies (official docs)](https://docs.ansible.com/ansible/latest/reference_appendices/test_strategies.html)
- [Safely Testing Ansible Playbooks Before Production](https://dstw.github.io/2025/06/03/testing-ansible-playbooks/)
- [How to Use Ansible for Canary Deployments](https://oneuptime.com/blog/post/2026-02-21-ansible-canary-deployments/view)
- [Choosing between testinfra and Ansible for tests](https://medium.com/opsops/choosing-between-testinfra-and-ansible-for-tests-e52a9329b3ec)
- [Test-driven Infrastructure with Ansible & Molecule](https://www.codecentric.de/en/knowledge-hub/blog/test-driven-infrastructure-ansible-molecule)
- [CI/CD for Your Homelab: Why It Matters and How to Start (2026)](https://corelab.tech/cicd_homelab/)
- [Simple selfhosted CI/CD with Woodpecker](https://xyquadrat.ch/blog/simple-ci-with-woodpecker/)
