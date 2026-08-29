## Replay broadcast state channel.
##
## Forked from `src/ctf/broadcast.nim`: the binary sprite stream stays the
## board renderer and this module produces the parallel JSON chrome the
## broadcast client reads to draw the scorebug, the feed, the ladder, the
## strata gauge, the transport and the endcard.
##
## Events are derived ONE SIM STEP AT A TIME (`stepEvents`) and accumulated by
## the caller across a playback frame, so the story stays exact even at 16x
## and is identical live and in replay.

import std/[json, strutils]

import sim

type
  BroadcastTracker* = object
    ## Per-server snapshot used to diff one sim step against the previous one.
    initialized: bool
    prevTick: int
    prevPhase: GamePhase
    unlocked: array[Milestone, bool]
    deepest: int
    z: int
    alive: bool
    blocksMined: int
    blocksPlaced: int
    itemsCrafted: int
    ironSmelted: int
    interrupts: int
    lastMinedBlock: string
    lastMinedRun: int

const BroadcastEventKinds* = [
  "turn", "plan", "say", "fallback", "milestone", "mine", "craft", "smelt",
  "place", "descend", "ascend", "lava", "bridge", "blocked", "death", "end"
]
  ## The closed enum `stepEvents` can emit, asserted by
  ## `tests/test_minecraft_events.nim`. The scrubber's BEAT kinds are the five
  ## subset `{milestone, newdepth, death, fallback, end}` - `newdepth` is a
  ## `descend` with `first: true`.

proc initBroadcastTracker*(): BroadcastTracker =
  result.prevPhase = Lobby
  result.deepest = 0
  result.alive = true

proc snapshot(tracker: var BroadcastTracker, sim: SimServer) =
  for m in Milestone:
    tracker.unlocked[m] = sim.ledger.unlocked[m]
  tracker.deepest = sim.deepestLevel
  tracker.z = sim.cog.z
  tracker.alive = sim.cog.alive
  tracker.blocksMined = sim.blocksMined
  tracker.blocksPlaced = sim.blocksPlaced
  tracker.itemsCrafted = sim.itemsCrafted
  tracker.ironSmelted = sim.ironSmelted
  tracker.interrupts = sim.interrupts
  tracker.prevTick = sim.tickCount
  tracker.prevPhase = sim.phase
  tracker.initialized = true

proc resync*(tracker: var BroadcastTracker, sim: SimServer) =
  tracker.snapshot(sim)

proc stepEvents*(sim: var SimServer, tracker: var BroadcastTracker,
    events: JsonNode) =
  ## Derives this step's broadcast events from the state delta. Nothing here
  ## fires unconditionally per tick, so the feed never floods.
  if not tracker.initialized:
    tracker.snapshot(sim)
    return
  let tick = sim.gameTicksElapsed()

  for m in Milestone:
    if sim.ledger.unlocked[m] and not tracker.unlocked[m]:
      events.add(%*{
        "k": "milestone", "t": tick, "id": $m, "index": ord(m),
        "points": milestonePoints(m),
        "n": sim.ledger.milestonesReached(),
        "of": ord(high(Milestone)) + 1
      })

  if sim.cog.z > tracker.z:
    events.add(%*{
      "k": "descend", "t": tick, "from": levelShortLabel(tracker.z),
      "to": levelShortLabel(sim.cog.z), "x": sim.cog.x, "y": sim.cog.y,
      "first": sim.deepestLevel > tracker.deepest
    })
  elif sim.cog.z < tracker.z:
    events.add(%*{
      "k": "ascend", "t": tick, "from": levelShortLabel(tracker.z),
      "to": levelShortLabel(sim.cog.z), "x": sim.cog.x, "y": sim.cog.y
    })

  if sim.blocksMined > tracker.blocksMined:
    events.add(%*{
      "k": "mine", "t": tick, "what": "block",
      "count": sim.blocksMined - tracker.blocksMined,
      "z": sim.cog.z, "x": sim.cog.x, "y": sim.cog.y
    })
  if sim.blocksPlaced > tracker.blocksPlaced:
    events.add(%*{
      "k": "place", "t": tick, "what": "block",
      "z": sim.cog.z, "x": sim.cog.x, "y": sim.cog.y
    })
  if sim.ironSmelted > tracker.ironSmelted:
    events.add(%*{"k": "smelt", "t": tick,
      "n": sim.ironSmelted - tracker.ironSmelted,
      "ingots": sim.cog.inventory[itIronIngot]})
  elif sim.itemsCrafted > tracker.itemsCrafted:
    events.add(%*{"k": "craft", "t": tick, "what": "item",
      "n": sim.itemsCrafted - tracker.itemsCrafted})
  if sim.interrupts > tracker.interrupts:
    events.add(%*{"k": "lava", "t": tick, "z": sim.cog.z, "x": sim.cog.x,
      "y": sim.cog.y, "adjacent": true})
  if tracker.alive and not sim.cog.alive:
    events.add(%*{"k": "death", "t": tick, "by": "lava"})
  if tracker.prevPhase != GameOver and sim.phase == GameOver:
    events.add(%*{
      "k": "end", "t": tick, "reason": sim.reasonText(),
      "endRule": sim.endRuleText(),
      "milestones": sim.ledger.milestonesReached(),
      "of": ord(high(Milestone)) + 1,
      "score": sim.ledger.episodeScore(sim.config.maxTicks)
    })
  tracker.snapshot(sim)

proc rosterJson*(sim: SimServer): JsonNode =
  ## One entry per seat. The seat's REAL policy name is spectator-side only;
  ## `alias` is the only name the model ever sees.
  result = newJArray()
  for seat in 0 ..< sim.seatCount():
    result.add(%*{
      "s": seat,
      "name": sim.realName(seat),
      "alias": seatAlias(seat),
      "pol": sim.realName(seat),
      "team": "red",
      "alive": sim.cog.alive,
      "lives": sim.ledger.milestonesReached(),
      "kind": (if seat < sim.seatPolicyKind.len: sim.seatPolicyKind[seat]
               else: "scripted")
    })

proc teamsJson(sim: SimServer): JsonNode =
  ## The inherited chrome renders whatever teams the frame carries. This game
  ## has ONE seat and no teams, so it carries exactly one entry and the plate
  ## it draws is the cog's.
  var policies = newJArray()
  policies.add(%sim.realName(0))
  result = newJObject()
  result["red"] = %*{
    "lives": sim.ledger.milestonesReached(),
    "prog": sim.ledger.milestoneScore(),
    "policies": policies
  }

proc ladderJson(sim: SimServer): JsonNode =
  result = newJArray()
  for m in Milestone:
    result.add(%*{
      "id": $m,
      "p": milestonePoints(m),
      "t": sim.ledger.tick[m]
    })

proc shaftsJson(sim: SimServer): JsonNode =
  result = newJArray()
  for z in 0 ..< sim.world.levelCount:
    for y in 0 ..< sim.world.levelSize:
      for x in 0 ..< sim.world.levelSize:
        if sim.world.hasShaftDown(x, y, z):
          result.add(%*[z, x, y])

proc knownOreJson(sim: SimServer): JsonNode =
  result = newJArray()
  var count = 0
  for z in 0 ..< sim.world.levelCount:
    for y in 0 ..< sim.world.levelSize:
      for x in 0 ..< sim.world.levelSize:
        if count >= 48:
          return
        if not sim.world.isSeen(x, y, z):
          continue
        let known = sim.world.knownAt(x, y, z)
        if known notin {bkCoalOre, bkIronOre, bkDiamondOre}:
          continue
        result.add(%*{"w": $known, "z": z, "x": x, "y": y})
        inc count

proc gameJson(sim: SimServer): JsonNode =
  ## Everything the appended game block draws: the ladder, the strata gauge,
  ## the inventory strip, the agent-view inset and the endcard columns.
  var inventory = newJObject()
  for item in Item:
    inventory[$item] = %sim.cog.inventory[item]
  var tools = newJObject()
  for tool in Tool:
    tools[$tool] = %sim.cog.tools[tool]
  var view = newJArray()
  for row in sim.viewRows():
    view.add(%row)
  %*{
    "x": sim.cog.x, "y": sim.cog.y, "z": sim.cog.z,
    "facing": $sim.cog.facing,
    "level": levelShortLabel(sim.cog.z),
    "levelLabel": levelLabel(sim.cog.z),
    "tier": sim.cog.tier(),
    "alive": sim.cog.alive,
    "size": sim.world.levelSize,
    "levels": sim.world.levelCount,
    "inv": inventory,
    "tools": tools,
    "ms": sim.ladderJson(),
    "n": sim.ledger.milestonesReached(),
    "of": ord(high(Milestone)) + 1,
    "score": sim.ledger.episodeScore(sim.config.maxTicks),
    "mscore": sim.ledger.milestoneScore(),
    "speed": sim.ledger.speedBonus(sim.config.maxTicks),
    "deepest": sim.deepestLevel,
    "shafts": sim.shaftsJson(),
    "ore": sim.knownOreJson(),
    "view": view,
    "vr": viewRadius(sim.config, sim.cog.z),
    "seen": sim.world.cellsSeen(),
    "cells": sim.config.levelCount * sim.config.levelSize *
      sim.config.levelSize,
    "mined": sim.blocksMined,
    "built": sim.blocksPlaced,
    "crafted": sim.itemsCrafted,
    "smelted": sim.ironSmelted,
    "dug": sim.shaftsDug,
    "bridges": sim.bridgesPlaced,
    "interrupts": sim.interrupts,
    "fallbacks": (if sim.fallbackTurns.len > 0: sim.fallbackTurns[0] else: 0),
    "turn": sim.turnsPlayed,
    "turns": sim.config.maxTurns,
    "death": sim.deathCause
  }

proc buildStateJson*(sim: SimServer, events: JsonNode, playing: bool,
    speed, maxTick: int, looping, transportEnabled: bool, mismatchTick: int,
    leadSeries: seq[seq[int]] = @[], startTick = 0, endHoldSeconds = 0,
    skipLulls = false, fastForwarding = false,
    lullSpans: seq[array[2, int]] = @[], beatEvents: JsonNode = nil): string =
  ## The broadcast chrome frame. Board-derived STATE is always present, so a
  ## frame reached by a SEEK still hydrates the scorebug and the endcard with
  ## no events at all.
  var state = %*{
    "t": sim.tickCount,
    "mt": sim.config.maxTicks,
    "ph": ($sim.phase).toLowerAscii,
    "lob": sim.lobbyStartSecondsRemaining(),
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForwarding,
    "en": transportEnabled,
    "mm": mismatchTick,
    "bs": 1,
    "pov": -1,
    "turnTicks": sim.config.turnTicks,
    "teams": sim.teamsJson(),
    "roster": sim.rosterJson(),
    "mc": sim.gameJson(),
    "events": (if events.isNil: newJArray() else: events)
  }

  if sim.feedDirectives.len > 0:
    ## The commander lines. This is where a spectator SEES the LLM playing.
    var records = newJArray()
    for record in sim.feedDirectives:
      try:
        records.add(parseJson(record))
      except CatchableError:
        discard
    state["directives"] = records

  if leadSeries.len > 0:
    ## Full-timeline milestone-score series, shipped ONCE per viewer, so the
    ## timeline draws at full width on the FIRST frame instead of growing in.
    var teamNames = newJArray()
    teamNames.add(%"red")
    var pts = newJArray()
    for point in leadSeries:
      var row = newJArray()
      for value in point:
        row.add(%value)
      pts.add(row)
    state["lead"] = %*{"teams": teamNames, "pts": pts}

  if not beatEvents.isNil and beatEvents.len > 0:
    state["beats"] = beatEvents

  if lullSpans.len > 0:
    var spans = newJArray()
    for span in lullSpans:
      spans.add(%*[span[0], span[1]])
    state["lulls"] = spans

  if sim.phase == GameOver:
    ## The endcard is STATE, not an event: present on every game-over frame so
    ## a viewer who seeks straight to the end still sees the verdict.
    var overTeams = newJObject()
    overTeams["red"] = %*{
      "lives": sim.ledger.milestonesReached(),
      "prog": sim.ledger.milestoneScore()
    }
    state["over"] = %*{
      "winner": (if sim.ledger.milestonesReached() >=
        sim.config.parMilestones: "red" else: ""),
      "draw": false,
      "timeLimit": sim.endRuleText() in [EndRuleTurnCap, EndRuleTickCap],
      "teams": overTeams,
      "endRule": sim.endRuleText(),
      "reason": sim.reasonText(),
      "milestones": sim.ledger.milestonesReached(),
      "of": ord(high(Milestone)) + 1,
      "score": sim.ledger.episodeScore(sim.config.maxTicks),
      "deepest": levelShortLabel(sim.deepestLevel),
      "tick": sim.gameTicksElapsed(),
      "death": sim.deathCause
    }
    if endHoldSeconds > 0:
      state["over"]["hold"] = %endHoldSeconds
      state["hold"] = %endHoldSeconds

  $state
