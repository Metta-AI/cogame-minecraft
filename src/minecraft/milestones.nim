## The eleven-rung ObtainDiamond ladder.
##
## Every rung is a PREDICATE OVER SIM STATE, evaluated by the engine every
## tick - never a self-report. That is the idea's "milestone verification from
## game state", implemented literally.
##
## The ledger itself is the starter's (`recordAchievement`,
## `src/ctf/roster.nim:640-648`) kept verbatim in shape and renamed
## `recordMilestone`, plus the parallel `milestoneTick` array this fork adds
## beside it so the viewer's timeline knows WHEN each rung lit.

import sim_types

type
  MilestoneLedger* = object
    unlocked*: array[Milestone, bool]
    tick*: array[Milestone, int]

proc initMilestoneLedger*(): MilestoneLedger =
  for m in Milestone:
    result.unlocked[m] = false
    result.tick[m] = -1

proc recordMilestone*(ledger: var MilestoneLedger, m: Milestone,
    atTick: int): bool =
  ## Deduplicating, exactly as the starter's ledger is: a rung unlocks once,
  ## permanently, and is never revoked. Returns true the one time it fires.
  if ledger.unlocked[m]:
    return false
  ledger.unlocked[m] = true
  ledger.tick[m] = atTick
  true

proc milestoneScore*(ledger: MilestoneLedger): int =
  ## The eleven-bit milestone mask read as an integer. `2^k > 2^0 + ... +
  ## 2^(k-1)`, so reaching one rung higher beats every possible combination of
  ## the rungs below it - an integer identity.
  for m in Milestone:
    if ledger.unlocked[m]:
      result = result or (1 shl ord(m))

proc milestonesReached*(ledger: MilestoneLedger): int =
  for m in Milestone:
    if ledger.unlocked[m]:
      inc result

proc deepestMilestone*(ledger: MilestoneLedger): int =
  ## The LARGEST unlocked index, or -1 when nothing is unlocked.
  result = -1
  for m in Milestone:
    if ledger.unlocked[m]:
      result = ord(m)

proc deepestTick*(ledger: MilestoneLedger): int =
  let deepest = ledger.deepestMilestone()
  if deepest < 0:
    return 0
  ledger.tick[Milestone(deepest)]

proc speedBonus*(ledger: MilestoneLedger, maxTicks: int): int =
  ## Purely a tie-break: `maxTicks` is always < 1000, so the bonus can never
  ## reach one rung's worth, and it rewards reaching the same rung earlier.
  if ledger.milestonesReached() == 0:
    return 0
  max(0, maxTicks - ledger.deepestTick())

proc episodeScore*(ledger: MilestoneLedger, maxTicks: int): int =
  ## `scores[0] = 1000 * milestoneScore + speedBonus`. Higher is better and
  ## every term only ever adds: the minimum is 0, the maximum 2 047 959.
  1000 * ledger.milestoneScore() + ledger.speedBonus(maxTicks)
