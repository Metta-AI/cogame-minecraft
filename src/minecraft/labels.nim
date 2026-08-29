## The board-label vocabulary contract.
##
## Forked from `src/ctf/labels.nim`: `labels.nim` deliberately scopes itself to
## the POLICY contract - every string this game can put in front of a model or
## draw as a board label - so `tests/test_minecraft_labels.nim` can assert the
## emitted vocabulary equals `tests/label_manifest.txt` and a label change is
## regenerated in the same commit.

import std/[algorithm, sequtils]

import sim, directives, baselines

proc boardLabelVocabulary*(): seq[string] =
  ## Every label this game emits into an observation, a prompt or the board.
  result = @[]
  for b in Block:
    result.add($b)
  for item in Item:
    result.add($item)
  for tool in Tool:
    result.add($tool)
  for primitive in Primitive:
    result.add($primitive)
  for name in MacroNames:
    result.add(name)
  for m in Milestone:
    result.add($m)
  for facing in Facing:
    result.add($facing)
  for baseline in Baseline:
    result.add($baseline)
  for why in BlockedWhy:
    if $why != "":
      result.add($why)
  for z in 0 .. 3:
    result.add(levelLabel(z))
  result.add(seatAlias(0))
  result.add(EndRuleDiamond)
  result.add(EndRuleDeath)
  result.add(EndRuleTurnCap)
  result.add(EndRuleTickCap)
  result.add(EndRuleWallClock)
  result.add(EndRuleFault)
  result.add(ReasonComplete)
  result.add(ReasonDeadline)
  result.add(ReasonFault)
  result.add(DeathCauseLava)
  result.add(DeathCauseNone)
  result = result.deduplicate()
  result.sort()
