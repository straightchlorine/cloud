#!/usr/bin/env python3
"""Dump installed distributions as name==version (pip is uninstalled in these images).

Run inside either image to record the exact dependency set an artefact was produced with:

    docker compose ... run --rm -T quantum-pipeline-gpu ... # no
    docker run --rm quantum-pipeline:gpu  python3 /bench/bench-dump-versions.py
    docker run --rm quantum-pipeline:cpu  python3 /bench/bench-dump-versions.py

Both Dockerfiles end with `pip uninstall -y pip`, so `pip freeze` is not available; this reads
the same metadata via importlib (stdlib, 3.8+).

Companion to bench-verify.py, which diffs the two images' versions against each other.
"""

import importlib.metadata as md

for dist in sorted(md.distributions(), key=lambda d: (d.metadata['Name'] or '').lower()):
    print(f"{dist.metadata['Name']}=={dist.version}")
