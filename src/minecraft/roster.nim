## Roster and results.
##
## Forked from `src/ctf/roster.nim`: the join/auth/slot resolution and the
## results-document builder (`squadResultsJson` -> `runResultsJson`). The
## identity vocabulary and the two name spaces are the starter's rule kept
## intact: the seat's ALIAS (`Alpha`) is the only name that reaches an
## observation, a prompt or the board; its REAL policy name lives in
## `results.names`, in the replay's join record and spectator-side only.

import std/[json]

import sim_types, sim_config, world, agent, milestones, sim_state

proc canAddPlayer*(sim: SimServer): bool =
  sim.players.len < sim.config.seatCountOf()

proc nextPlayerSlot*(sim: SimServer): int =
  sim.players.len

proc slotOccupied*(sim: SimServer, slot: int): bool =
  for player in sim.players:
    if player.joinOrder == slot:
      return true
  false

proc resolvePlayerSlot*(sim: SimServer, address, token: string,
    requestedSlot: int): int =
  ## Returns the slot a seat should use, or raises on rejection.
  if requestedSlot >= MaxPlayers:
    raise newException(MinecraftError, "Player slot must be between 0 and 7.")
  if token.len > 0 and sim.config.hasConfiguredTokens() and
      not sim.config.hasConfiguredToken(token):
    raise newException(MinecraftError, "Player token is not configured.")
  if requestedSlot >= 0:
    if requestedSlot >= sim.config.seatCountOf():
      raise newException(MinecraftError,
        "Player slot is outside configured roster.")
    if sim.slotOccupied(requestedSlot):
      raise newException(MinecraftError,
        "Player slot " & $requestedSlot & " is already occupied.")
    return requestedSlot
  let bySlot = sim.config.slotForToken(token)
  if bySlot >= 0 and not sim.slotOccupied(bySlot):
    return bySlot
  if not sim.canAddPlayer():
    raise newException(MinecraftError, "No available player slot.")
  sim.nextPlayerSlot()

proc addPlayer*(sim: var SimServer, address: string, requestedSlot: int,
    token: string): int =
  ## Seats one join and returns its player index.
  let slot = sim.resolvePlayerSlot(address, token, requestedSlot)
  if sim.slotOccupied(slot):
    raise newException(MinecraftError,
      "Player slot " & $slot & " is already occupied.")
  sim.players.add(PlayerRecord(address: address, joinOrder: slot,
    token: token))
  if slot >= 0 and slot < sim.seatNames.len:
    sim.seatNames[slot] = address
  sim.players.len - 1

proc removePlayerAt*(sim: var SimServer, playerIndex: int) =
  ## A seat that drops keeps its cog for the whole episode - the row is left
  ## in place so nothing renumbers mid-replay. Only the live socket goes.
  if playerIndex >= 0 and playerIndex < sim.deadSeats.len:
    sim.deadSeats[playerIndex] = true

proc realName*(sim: SimServer, seat: int): string =
  if seat >= 0 and seat < sim.seatNames.len and sim.seatNames[seat].len > 0:
    return sim.seatNames[seat]
  if seat >= 0 and seat < sim.config.slots.len and
      sim.config.slots[seat].name.len > 0:
    return sim.config.slots[seat].name
  "Baseline (" & $(seat + 1) & ")"

proc milestoneIdsJson*(): JsonNode =
  result = newJArray()
  for m in Milestone:
    result.add(%($m))

proc toolsOwnedJson(sim: SimServer): JsonNode =
  result = newJArray()
  for tool in Tool:
    if sim.cog.tools[tool]:
      result.add(%($tool))

proc runResultsJson*(sim: SimServer): string =
  ## The closed results schema. Adding a key means updating this proc, the
  ## manifest's `results_schema` and `tools/ci/docker_smoke.sh`'s expected-key
  ## set in the same commit - Coworld schemas are closed and undeclared keys
  ## are dropped.
  let
    maxTicks = sim.config.maxTicks
    score = sim.ledger.episodeScore(maxTicks)
    reached = sim.ledger.milestonesReached()
    deepest = sim.ledger.deepestMilestone()
    won = reached >= sim.config.parMilestones
  var
    points = newJArray()
    unlocked = newJArray()
    ticks = newJArray()
    perLevel = newJArray()
    names = newJArray()
    aliases = newJArray()
    scores = newJArray()
    win = newJArray()
    kinds = newJArray()
    llm = newJArray()
    fallbacks = newJArray()
    dead = newJArray()
  for m in Milestone:
    points.add(%milestonePoints(m))
    unlocked.add(%sim.ledger.unlocked[m])
    ticks.add(%sim.ledger.tick[m])
  var levelSum = 0
  for i in 0 ..< sim.config.levelCount:
    let value = if i < sim.ticksPerLevel.len: sim.ticksPerLevel[i] else: 0
    levelSum += value
    perLevel.add(%value)
  for seat in 0 ..< sim.seatCount():
    names.add(%sim.realName(seat))
    aliases.add(%seatAlias(seat))
    scores.add(%score)
    win.add(%won)
    kinds.add(%(if seat < sim.seatPolicyKind.len and
      sim.seatPolicyKind[seat].len > 0: sim.seatPolicyKind[seat]
      else: "scripted"))
    llm.add(%(if seat < sim.llmTurns.len: sim.llmTurns[seat] else: 0))
    fallbacks.add(%(if seat < sim.fallbackTurns.len: sim.fallbackTurns[seat]
      else: 0))
    dead.add(%(if seat < sim.deadSeats.len: sim.deadSeats[seat] else: false))

  var node = %*{
    "names": names,
    "aliases": aliases,
    "scores": scores,
    "win": win,
    "winner": (if won: %0 else: newJNull()),
    "reason": sim.reasonText(),
    "endRule": sim.endRuleText(),
    "variant": sim.variantName(),
    "seed": sim.config.seed,
    "milestoneIds": milestoneIdsJson(),
    "milestonePoints": points,
    "milestoneUnlocked": unlocked,
    "milestoneTick": ticks,
    "milestonesReached": reached,
    "milestonesOf": ord(high(Milestone)) + 1,
    "milestoneScore": sim.ledger.milestoneScore(),
    "parMilestones": sim.config.parMilestones,
    "deepestMilestone": (if deepest < 0: "none" else: $Milestone(deepest)),
    "deepestTick": sim.ledger.deepestTick(),
    "speedBonus": sim.ledger.speedBonus(maxTicks),
    "deathCause": sim.deathCause,
    "deepestLevel": sim.deepestLevel,
    "ticksPerLevel": perLevel,
    "cellsSeen": sim.world.cellsSeen(),
    "cellsTotal": sim.config.levelCount * sim.config.levelSize *
      sim.config.levelSize,
    "blocksMined": sim.blocksMined,
    "blocksPlaced": sim.blocksPlaced,
    "itemsCrafted": sim.itemsCrafted,
    "ironSmelted": sim.ironSmelted,
    "shaftsDug": sim.shaftsDug,
    "bridgesPlaced": sim.bridgesPlaced,
    "coalMined": sim.coalMined,
    "ironOreMined": sim.ironOreMined,
    "diamondsMined": sim.diamondsMined,
    "invLog": sim.cog.inventory[itLog],
    "invPlanks": sim.cog.inventory[itPlanks],
    "invStick": sim.cog.inventory[itStick],
    "invCobblestone": sim.cog.inventory[itCobblestone],
    "invCoal": sim.cog.inventory[itCoal],
    "invRawIron": sim.cog.inventory[itRawIron],
    "invIronIngot": sim.cog.inventory[itIronIngot],
    "invDiamond": sim.cog.inventory[itDiamond],
    "toolsOwned": sim.toolsOwnedJson(),
    "interrupts": sim.interrupts,
    "primitivesExecuted": sim.primitivesExecuted,
    "actionsDropped": sim.actionsDropped,
    "macrosUnreachable": sim.macrosUnreachable,
    "repliesRepaired": sim.repliesRepaired,
    "finalTick": sim.gameTicksElapsed(),
    "turnsPlayed": sim.turnsPlayed,
    "policyKinds": kinds,
    "llmTurns": llm,
    "fallbackTurns": fallbacks,
    "deadSeats": dead,
    "stopDetail": sim.stopDetail.truncateRunes(MaxFallbackDetailRunes)
  }
  # `ticksPerLevel` is always levelCount entries SUMMING TO finalTick: the
  # per-level counter only advances on a Playing tick, so any drift is a bug
  # in the tick loop and is corrected here rather than shipped.
  let final = sim.gameTicksElapsed()
  if levelSum != final and sim.config.levelCount > 0:
    var fixed = newJArray()
    for i in 0 ..< sim.config.levelCount:
      var value = if i < sim.ticksPerLevel.len: sim.ticksPerLevel[i] else: 0
      if i == 0:
        value += final - levelSum
      fixed.add(%max(0, value))
    node["ticksPerLevel"] = fixed
  $node
