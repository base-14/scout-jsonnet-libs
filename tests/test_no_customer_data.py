"""Fixtures and docs must not carry real deployment identifiers.

This repository is public, which constrains how the check itself can be
written: **a denylist of real names would be the leak it exists to prevent.**

So the patterns here are structural — they match the *shape* of infrastructure
identifiers rather than naming anyone:

  - datasource uids       ds-<word>-<word>
  - fully-qualified hosts  <host>.<domain>.<tld>, three labels or more

Hashing specific names instead was considered and rejected: a short, guessable
word yields to a dictionary attack in seconds, so it would be reassurance
rather than protection.

Bare product or company names cannot be caught structurally. A deployment that
needs those covered supplies them from outside the repository, where they are
not published:

    SCOUT_DENY_EXTRA='foocorp|barinc' uv run --frozen pytest

Set that in internal CI. It is deliberately absent here.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Shapes that real infrastructure identifiers take. These name nobody, so this
# file is safe to publish.
DENY = [
    # Datasource uids, e.g. ds-<cluster>-<engine>
    r"\bds-[a-z0-9]+-[a-z0-9-]{3,}\b",
    # Hosts with three or more labels. Two-label domains (example.com,
    # base14.io) are almost always documentation or a project link; three
    # labels usually means someone pasted a real endpoint.
    r"\b[a-z0-9][a-z0-9-]*\.[a-z0-9-]+\.(?:com|net|io|dev|sh|internal|local)\b",
]

# Documented placeholders and legitimate project links, exempt by construction.
ALLOW = re.compile(
    r"""
      example\.com
    | \bds-app(?:-stg)?\b
    | raw\.githubusercontent\.com
    | docs\.github\.com
    """,
    re.X | re.I,
)

ALLOWED_SUFFIXES = {".libsonnet", ".jsonnet", ".py", ".md", ".json", ".toml", ".yaml", ".yml"}


def patterns() -> re.Pattern:
    extra = os.environ.get("SCOUT_DENY_EXTRA", "").strip()
    parts = list(DENY) + ([extra] if extra else [])
    return re.compile("|".join(parts), re.I)


def tracked_files() -> list[Path]:
    out = subprocess.run(
        ["git", "ls-files"], cwd=ROOT, check=True, capture_output=True, text=True
    )
    return [ROOT / p for p in out.stdout.split()]


def test_no_real_deployment_identifiers_in_tracked_files():
    pattern = patterns()
    hits = []
    for path in tracked_files():
        if path.suffix not in ALLOWED_SUFFIXES or path.name == Path(__file__).name:
            continue
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            for m in pattern.finditer(line):
                if ALLOW.search(m.group(0)):
                    continue
                hits.append(f"{path.relative_to(ROOT)}:{lineno}: {m.group(0)}")
    assert not hits, (
        "identifiers that look like a real deployment, in a public repo:\n  "
        + "\n  ".join(hits)
        + "\n\nUse the placeholders in CONTRIBUTING.md, or extend ALLOW if this "
          "is a legitimate project link."
    )


def test_extra_patterns_are_honoured():
    """The env hook must actually apply — internal CI depends on it."""
    os.environ["SCOUT_DENY_EXTRA"] = "zzzsentinelzzz"
    try:
        assert patterns().search("a zzzsentinelzzz b")
    finally:
        del os.environ["SCOUT_DENY_EXTRA"]
