#!/bin/bash
# Fails when a PR reuses a GameVersion the base branch has ALREADY spent for a
# DIFFERENT rule.
#
# Why this exists: a GameVersion is claimed across BRANCHES, and nothing else in
# the build enforces that. Two branches can each be perfectly current with main
# and still pick the same next number, because neither can see the other's
# choice. The collision then lands silently, and a replay's recorded version no
# longer identifies the rules that produced it — the replay still LOADS (the
# version string matches) and then re-simulates wrong, which is worse than a
# refusal. See AGENTS.md, "A GameVersion number is claimed across BRANCHES".
#
# The non-obvious part: comparing the NUMBER cannot detect the collision,
# because the colliding branch and the base BOTH read e.g. "42". What
# distinguishes them is the RULE the number is attached to — the headline on the
# changelog comment. So: same number + different rule headline = two meanings
# for one version = fail.
#
# Usage:
#   tools/ci/check_gameversion.sh <base-ref> [head-ref]
# Examples:
#   tools/ci/check_gameversion.sh origin/main            # check working HEAD
#   tools/ci/check_gameversion.sh origin/main my-branch  # check a branch
#
# Exit 0 = fine, exit 1 = collision (or the branch is behind its base).
set -uo pipefail

BASE="${1:?usage: check_gameversion.sh <base-ref> [head-ref]}"
HEAD_REF="${2:-HEAD}"
CONST_FILE="src/minecraft/sim_types.nim"

line() {
  # The GameVersion declaration line from one ref, or empty if unreadable.
  git show "$1:$CONST_FILE" 2>/dev/null | grep -m1 'GameVersion\* ='
}
ver()  { line "$1" | grep -o '"[0-9]*"' | tr -d '"'; }
rule() { line "$1" | sed 's/.*## //'; }

base_v=$(ver "$BASE"); head_v=$(ver "$HEAD_REF")

if [ -z "$base_v" ] || [ -z "$head_v" ]; then
  echo "::error::could not read GameVersion from $CONST_FILE" \
       "(base='$BASE' -> '${base_v:-?}', head='$HEAD_REF' -> '${head_v:-?}')." \
       "If the const was renamed, update tools/ci/check_gameversion.sh."
  exit 1
fi

echo "base ($BASE) = GV$base_v — $(rule "$BASE")"
echo "head ($HEAD_REF) = GV$head_v — $(rule "$HEAD_REF")"

if [ "$head_v" -gt "$base_v" ]; then
  echo "OK: GV$head_v is above the base's GV$base_v."
  exit 0
fi

if [ "$head_v" -lt "$base_v" ]; then
  echo "::error::GV$head_v is BELOW the base's GV$base_v — this branch is" \
       "behind. Rebase onto $BASE, then re-derive any version-sensitive work" \
       "(the GameVersion const, replay fixtures) against the updated code."
  exit 1
fi

# Equal numbers. Fine only if this branch is not claiming a DIFFERENT rule —
# which is the overwhelmingly common case: every PR that does not touch the
# gameplay rules leaves both the number and the headline untouched.
if [ "$(rule "$BASE")" = "$(rule "$HEAD_REF")" ]; then
  echo "OK: GV$head_v unchanged from the base — no rule change claimed."
  exit 0
fi

echo "::error::GV$head_v is already spent on $BASE, for a DIFFERENT rule." \
     "Another branch merged your number first."
echo "  $BASE: $(rule "$BASE")"
echo "  this branch: $(rule "$HEAD_REF")"
echo "Renumber to GV$((base_v + 1)) — or higher, if an open PR claims that too;" \
     "AGENTS.md has a scan that lists every branch's claim — and RE-RECORD the" \
     "replay fixtures against the updated base. Fixtures cut against the old" \
     "number fail the replay version gate the moment the other change lands."
exit 1
