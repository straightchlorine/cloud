set shell := ["bash", "-euo", "pipefail", "-c"]

roles := `ls -d roles/*/molecule | cut -d/ -f2 | tr '\n' ' '`

# Recipes use the repo venv that `just setup` creates.
export PATH := justfile_directory() + "/.venv/bin:" + env_var("PATH")

_ok   := "[  OK  ]"
_fail := "[ FAIL ]"
_info := "[ INFO ]"
_run  := "[ RUN  ]"

# Show available recipes
[group: 'help']
default:
    @just --list --unsorted

# One-time environment setup (venv, deps, collections, hooks, git config)
[group: 'setup']
setup: _setup-venv _setup-deps _setup-collections _setup-hooks _setup-git-config
    @echo "{{ _ok }} Setup complete -- activate with: source .venv/bin/activate"

[private]
_setup-venv:
    @echo "{{ _run }} Creating virtual environment"
    # An existing venv may lack pip, for example one created by uv with --no-pip.
    # Running ensurepip guarantees that the _setup-deps recipe can call `python -m pip`.
    @test -d .venv || python3 -m venv .venv
    @.venv/bin/python -m ensurepip --upgrade -q 2>/dev/null || true
    @echo "{{ _ok }} Virtual environment ready"

[private]
_setup-deps:
    @echo "{{ _run }} Installing Python dependencies"
    # Calling `python -m pip` avoids `.venv/bin/pip`, which uv-created venvs may not have.
    @.venv/bin/python -m pip install --upgrade pip wheel setuptools -q
    @.venv/bin/python -m pip install -r requirements.txt -q
    @echo "{{ _ok }} Python dependencies installed"

[private]
_setup-collections:
    @echo "{{ _run }} Installing Ansible collections"
    @scripts/install-collections.sh --force > /dev/null
    @echo "{{ _ok }} Ansible collections installed"

[private]
_setup-hooks:
    @echo "{{ _run }} Installing git hooks"
    @.venv/bin/pre-commit install > /dev/null 2>&1
    @.venv/bin/pre-commit install --hook-type pre-push -c .pre-push-config.yaml > /dev/null 2>&1
    @echo "{{ _ok }} Pre-commit and pre-push hooks installed"

[private]
_setup-git-config:
    @echo "{{ _run }} Configuring repo-local git settings"
    @git config --local pull.rebase true
    @git config --local push.default current
    @git config --local push.autoSetupRemote true
    @git config --local merge.conflictstyle zdiff3
    @git config --local diff.algorithm histogram
    @git config --local rerere.enabled true
    @git config --local fetch.prune true
    @git config --local core.autocrlf input
    @git config --local branch.autoSetupMerge always
    @git config --local rebase.autoStash true
    @echo "{{ _ok }} Git config applied"

# Molecule: every scenario of a role at once, every role in turn, or one scenario
[group: 'test']
test role="" scenario="":
    #!/usr/bin/env bash
    set -uo pipefail
    [ -z "{{ role }}" ] || exec scripts/molecule-test.sh {{ role }} {{ scenario }}
    rc=0
    for r in {{ roles }}; do scripts/molecule-test.sh "$r" || rc=1; done
    exit $rc

# Converge + verify on a scenario's live container; `molecule destroy -s <scenario>` in the role ends it
[group: 'test']
iterate role scenario:
    scripts/molecule-test.sh --iterate {{ role }} {{ scenario }}

# Syntax-check all playbooks
[group: 'test']
syntax:
    @ANSIBLE_ROLES_PATH=$PWD/roles ansible-playbook --syntax-check playbooks/*.yml playbooks/*/*.yml >/dev/null
    @echo "{{ _ok }} playbook syntax"

# Run all linters (ansible-lint + yamllint)
[group: 'lint']
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "{{ _run }} ansible-lint"
    ansible-lint --offline roles/ playbooks/
    echo "{{ _ok }} ansible-lint"
    echo "{{ _run }} yamllint"
    yamllint -s -c .yamllint .
    echo "{{ _ok }} yamllint"
    echo "{{ _ok }} All linters passed"

# Deploy full infrastructure
[group: 'deploy']
[confirm("Deploy to ALL hosts. Continue?")]
deploy:
    ansible-playbook playbooks/site.yml --ask-vault-pass

# Deploy one playbook from playbooks/ (for example: just deploy-service media)
[group: 'deploy']
[confirm("Deploy this service. Continue?")]
deploy-service playbook:
    ansible-playbook playbooks/{{ playbook }}.yml --ask-vault-pass
