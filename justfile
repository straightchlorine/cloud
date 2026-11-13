set shell := ["bash", "-euo", "pipefail", "-c"]

roles := `ls -d roles/*/molecule | cut -d/ -f2 | tr '\n' ' '`

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
    @.venv/bin/ansible-galaxy collection install -r requirements.yml --force > /dev/null
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

# Run molecule tests (all roles, or: just test <role> [scenario])
[group: 'test']
test role="" scenario="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{ role }}" ]; then
        echo "{{ _run }} Testing all roles"
        failed=""
        for r in {{ roles }}; do
            echo "{{ _run }} $r"
            if (cd roles/$r && uv run molecule test 2>&1); then
                echo "{{ _ok }} $r"
            else
                echo "{{ _fail }} $r"
                failed="$failed $r"
            fi
        done
        if [ -n "$failed" ]; then
            echo "{{ _fail }} Failed:$failed"
            exit 1
        fi
        echo "{{ _ok }} All roles passed"
    elif [ -z "{{ scenario }}" ]; then
        echo "{{ _run }} {{ role }}"
        cd roles/{{ role }} && uv run molecule test
        echo "{{ _ok }} {{ role }}"
    else
        echo "{{ _run }} {{ role }} ({{ scenario }})"
        cd roles/{{ role }} && uv run molecule test --scenario-name {{ scenario }}
        echo "{{ _ok }} {{ role }} ({{ scenario }})"
    fi

# Syntax-check all playbooks
[group: 'test']
syntax:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "{{ _run }} Checking playbook syntax"
    failed=0
    for pb in playbooks/*.yml playbooks/*/*.yml; do
        [ -f "$pb" ] || continue
        if ansible-playbook --syntax-check "$pb" > /dev/null 2>&1; then
            echo "{{ _ok }} $pb"
        else
            echo "{{ _fail }} $pb"
            failed=1
        fi
    done
    [ "$failed" -eq 0 ] || { echo "{{ _fail }} Syntax errors found"; exit 1; }
    echo "{{ _ok }} All playbooks valid"

# Run all linters (ansible-lint + yamllint)
[group: 'lint']
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "{{ _run }} ansible-lint"
    ansible-lint roles/ playbooks/
    echo "{{ _ok }} ansible-lint"
    echo "{{ _run }} yamllint"
    yamllint -s .
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
