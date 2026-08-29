#!/usr/bin/env python3
"""Fixture tests for the next_coworld_version picker (stdlib only, no network).

Run from anywhere: python3 tools/ci/test_next_coworld_version.py
The upload workflow runs this before every version computation.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from next_coworld_version import compute_next  # noqa: E402


def row(name, version, canonical=False, rid="cow_test"):
    return {"id": rid, "name": name, "version": version, "canonical": canonical}


def expect_exit(fn, fragment):
    try:
        fn()
    except SystemExit as e:
        msg = str(e)
        assert fragment in msg, f"expected {fragment!r} in error, got: {msg}"
        return
    raise AssertionError(f"expected SystemExit containing {fragment!r}, none raised")


# THE defect scenario (2026-07-30/31 wedge): canonical 0.7.127, orphan
# NON-canonical 0.7.128 above it. canonical-based picker returns 0.7.128
# and 409s forever; this picker must return 0.7.129.
orphan_rows = [
    row("ctf", "0.7.128", canonical=False),  # the orphan (newest-first)
    row("ctf", "0.7.127", canonical=True),
    row("ctf", "0.7.126", canonical=False),
    row("paintbot", "0.7.138", canonical=True),
]
assert compute_next(orphan_rows, "ctf") == "0.7.129"

# Clean registry: max row IS the canonical -> plain patch bump.
assert compute_next(orphan_rows, "paintbot") == "0.7.139"

# Numeric (not lexicographic) ordering: 0.7.9 < 0.7.10 < 0.7.100.
numeric_rows = [
    row("ctf", "0.7.9", canonical=True),
    row("ctf", "0.7.100", canonical=False),
    row("ctf", "0.7.10", canonical=False),
]
assert compute_next(numeric_rows, "ctf") == "0.7.101"

# Other names never leak into the computation.
mixed = orphan_rows + [row("speedrun-wow", "9.9.9", canonical=True)]
assert compute_next(mixed, "ctf") == "0.7.129"

# Under-read guards: a fetch that misses the canonical row must hard-fail,
# never emit a number that can re-collide.
expect_exit(lambda: compute_next([row("ctf", "0.7.5")], "ctf"), "no canonical row")
expect_exit(lambda: compute_next([], "ctf"), "no rows for coworld")
expect_exit(lambda: compute_next(orphan_rows, "nosuch"), "no rows for coworld")

# Unparseable version for our name is a hard failure, not a silent skip —
# a skipped max row would re-collide.
expect_exit(
    lambda: compute_next([row("ctf", "0.7.x"), row("ctf", "0.7.1", canonical=True)], "ctf"),
    "non-semver",
)

print("test_next_coworld_version: all assertions passed")
