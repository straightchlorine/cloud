#!/usr/bin/env python3
"""Check a side checkout against the live benchmark stack (read-only).

Usage: side.py check DIR     (via `gpu-qp side check DIR`)

Renders DIR's compose config with compose/side.override.yml as project qpside-<name of DIR> and
compares it with what the bench stack runs. Prints `FAIL<TAB>check<TAB>detail` per problem, `INFO`
lines for protected images used without a build and `OK` when nothing is wrong; exit 1 on any
FAIL. Secret values are never printed.

Environment (the bench.env values, set by cli.sh): GPU_QP_HOME, GPU_QP_SOURCE, GPU_QP_BENCH_ROOT,
GPU_QP_MIN_FREE_GB, GPU_QP_SIDE_MARGIN_GB, GPU_QP_PROTECTED_IMAGES (space-separated).
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

BENCH_VOLUME_PREFIXES = ('quantum-ml-', 'quantum-garage-')
BENCH_NETWORK = 'quantum-ml-network'
SOCKETS = ('/var/run/docker.sock', '/run/docker.sock')
LABEL = 'label=com.docker.compose.project=ml'


def docker(*args: str) -> subprocess.CompletedProcess:
    cmd = ['docker', *args]
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=20, check=False)
    except (OSError, subprocess.TimeoutExpired) as e:
        return subprocess.CompletedProcess(cmd, 124, '', str(e))


def dotenv(path: str) -> dict[str, str]:
    env: dict[str, str] = {}
    try:
        text = Path(path).read_text()
    except OSError:
        return env
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, _, value = line.partition('=')
        key = key.removeprefix('export ').strip()
        env[key] = value.strip().strip('\'"')
    return env


def lock_holder(root: str) -> str | None:
    """The run named in .active while some process holds the bench lock, else None."""
    try:
        fd = os.open(os.path.join(root, '.lock'), os.O_RDONLY)
    except OSError:
        return None
    try:
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        return None
    except BlockingIOError:
        pass
    finally:
        os.close(fd)
    try:
        return (Path(root) / '.active').read_text().split()[0]
    except (OSError, IndexError):
        return 'unknown run'


def inside(path: str, base: str) -> bool:
    return path == base or path.startswith(base.rstrip('/') + '/')


def main(directory: str) -> int:
    d = os.path.realpath(directory)
    if not os.path.isdir(d):
        print(f'[FAIL] no such directory: {directory}', file=sys.stderr)
        return 1
    project = 'qpside-' + re.sub(r'[^a-z0-9_-]', '-', os.path.basename(d).lower())
    compose = f'{d}/compose'
    render = docker(
        'compose', '-p', project, '--env-file', f'{d}/.env', '-f', f'{compose}/docker-compose.ml.yaml',
        '-f', f'{compose}/side.override.yml', '--profile', '*', 'config', '--format', 'json',
    )
    if render.returncode:
        print(f'FAIL\tcompose\t{(render.stderr.strip().splitlines() or [""])[0]}')
        return 1
    if docker('info').returncode:
        print('FAIL\tdocker\tunreachable')
        return 1

    cfg = json.loads(render.stdout)
    services: dict = cfg.get('services') or {}
    bad = 0

    def fail(check: str, detail: str) -> None:
        nonlocal bad
        bad += 1
        print(f'FAIL\t{check}\t{detail}')

    home = os.path.realpath(os.environ['GPU_QP_HOME'])
    protected = os.environ['GPU_QP_PROTECTED_IMAGES'].split()
    bench = dotenv(os.path.join(os.environ['GPU_QP_SOURCE'], '.env'))
    s3 = bench.get('S3_ENDPOINT', '')
    volumes = set(docker('volume', 'ls', '-q', '--filter', LABEL).stdout.split())
    networks = set(docker('network', 'ls', '--filter', LABEL, '--format', '{{.Name}}').stdout.split()) | {BENCH_NETWORK}

    holder = lock_holder(os.environ['GPU_QP_BENCH_ROOT'])
    if holder:
        fail('lock', f'the bench lock is held by {holder}: a run is in progress, side work would disturb its timings')

    for svc, s in sorted(services.items()):
        mode = s.get('network_mode')
        if mode and not mode.startswith('container:qpside-'):
            fail('network_mode', f'{svc}: {mode} (only a qpside container is allowed)')
        for v in s.get('volumes') or []:
            paths = [v.get('source', ''), v.get('target', '')] if isinstance(v, dict) else str(v).split(':')
            if any(x in SOCKETS for x in paths):
                fail('docker.sock', f'{svc} mounts the Docker socket')
            if isinstance(v, dict) and v.get('type') == 'bind':
                src = os.path.realpath(os.path.join(d, v.get('source', '')))  # relative: against DIR
                if inside(src, home) and not inside(src, d):
                    fail('bind', f'{svc}: {src} is under {home}, outside {d}')
        image = s.get('image') or ''
        if image in protected or image.startswith('ml-'):
            if 'build' in s:
                fail('image', f'{svc}: builds {image}, which would retag the bench image')
            else:
                print(f'INFO\timage\t{svc}: uses {image} without building it')
        for key, value in sorted((s.get('environment') or {}).items()):
            if not value:
                continue
            if s3 and str(value) == s3:
                fail('env', f'{svc}: {key} is the bench S3_ENDPOINT')
            elif key.startswith('R2_') and bench.get(key) == str(value):
                fail('env', f'{svc}: {key} is the bench value')

    for key, v in sorted((cfg.get('volumes') or {}).items()):
        name = (v or {}).get('name') or key
        if name in volumes or name.startswith(BENCH_VOLUME_PREFIXES):
            fail('volume', f'{key}: {name} is a bench volume')
    for key, n in sorted((cfg.get('networks') or {}).items()):
        name = (n or {}).get('name') or key
        if name in networks:
            fail('network', f'{key}: {name} is the bench network')

    free = shutil.disk_usage('/').free // 2**30
    floor, margin = int(os.environ['GPU_QP_MIN_FREE_GB']), int(os.environ['GPU_QP_SIDE_MARGIN_GB'])
    if free < floor + margin:
        fail('disk', f'{free}G free on /, need {floor + margin}G (floor {floor}G + margin {margin}G)')
    if not bad:
        print('OK')
    return 1 if bad else 0


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] != 'check':
        print('usage: gpu-qp side check DIR', file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[2]))
