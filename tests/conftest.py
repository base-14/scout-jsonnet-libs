"""Shared jsonnet evaluation for the library's tests.

The library is pure jsonnet, so its tests drive it the way a consumer does:
evaluate an expression against the repo root and parse the JSON. No repo state
is involved, which is why these tests live here rather than with a consumer.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def jsonnet_eval(expr: str):
    """Evaluate a jsonnet expression with the library on the search path."""
    out = subprocess.run(
        ["jsonnet", "-J", str(ROOT), "-e", expr],
        check=True, cwd=ROOT, capture_output=True, text=True,
    )
    return json.loads(out.stdout)
