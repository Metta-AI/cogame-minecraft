## The seat's observation: exactly what is visible and what is hidden.
##
## The guiding line is the design note's: the cog knows what it is carrying,
## what it has already done, and exactly what it has looked at - and nothing
## about a floor it has not cut through.
##
## HIDDEN, always: the episode seed; every cell never observed, on every level;
## every block on a level the cog has not descended to; every noise-field value
## and every generator threshold; every future draw; the cog's own score;
## `parMilestones`; and its own real player name.

import std/[algorithm, json]

import sim_types, world, agent, milestones, sim_state

type
  OreSighting = object
    what: string
    z, x, y: int
    dist: int
    hasDist: bool
    seenTick: int

proc glyphAt(sim: SimServer, x, y, z: int): char =
  ## The one glyph the seat reads for a cell it can see. `v` and `^` are
  ## OVERLAYS, not blocks: they describe the floor and the ceiling of a cell
  ## rather than the cell itself, and a cell with both reads `v`.
  if x == sim.cog.x and y == sim.cog.y and z == sim.cog.z:
    return '@'
  if not sim.world.isSeen(x, y, z):
    return '?'
  if sim.world.hasShaftDown(x, y, z):
    return 'v'
  if z > 0 and sim.world.hasShaftDown(x, y, z - 1):
    return '^'
  sim.world.knownAt(x, y, z).glyph()

proc viewRows*(sim: SimServer): seq[string] =
  ## The (2r+1)^2 square centred on the cog on the cog's CURRENT level, in
  ## world orientation - the one an LLM reads without a coordinate transform.
  ## No occlusion and no line-of-sight: the depth-dependent radius already
  ## does the work a light model would.
  let r = viewRadius(sim.config, sim.cog.z)
  result = newSeq[string](2 * r + 1)
  for row in 0 .. 2 * r:
    var line = newString(2 * r + 1)
    for col in 0 .. 2 * r:
      let
        x = sim.cog.x - r + col
        y = sim.cog.y - r + row
      line[col] =
        if not sim.world.inBounds(x, y, sim.cog.z): 'B'
        else: sim.glyphAt(x, y, sim.cog.z)
    result[row] = line

proc legendJson(): JsonNode =
  %*{
    ".": "grass", ",": "sand", "~": "water", "T": "oak tree",
    "#": "stone", "c": "coal ore", "i": "iron ore",
    "D": "diamond ore", "=": "tunnel",
    "!": "LAVA (a step into it kills you)",
    "B": "bedrock", "t": "crafting table", "f": "furnace",
    "v": "shaft DOWN from here", "^": "shaft UP from here",
    "@": "you", "?": "never seen"
  }

proc nearestOf(sim: SimServer, want: string): JsonNode =
  ## The closest KNOWN cell on the CURRENT level of one kind, or null. This is
  ## what makes `goto` usable and it is the single most load-bearing field in
  ## the observation.
  var
    bestX = -1
    bestY = -1
    bestDist = high(int)
  let z = sim.cog.z
  for y in 0 ..< sim.world.levelSize:
    for x in 0 ..< sim.world.levelSize:
      if not sim.world.isSeen(x, y, z):
        continue
      var hit = false
      case want
      of "shaft_down": hit = sim.world.hasShaftDown(x, y, z)
      of "shaft_up": hit = z > 0 and sim.world.hasShaftDown(x, y, z - 1)
      of "tree": hit = sim.world.knownAt(x, y, z) == bkTree
      of "water": hit = sim.world.knownAt(x, y, z) == bkWater
      of "stone": hit = sim.world.knownAt(x, y, z) == bkStone
      of "coal_ore": hit = sim.world.knownAt(x, y, z) == bkCoalOre
      of "iron_ore": hit = sim.world.knownAt(x, y, z) == bkIronOre
      of "diamond_ore": hit = sim.world.knownAt(x, y, z) == bkDiamondOre
      of "lava": hit = sim.world.knownAt(x, y, z) == bkLava
      of "crafting_table": hit = sim.world.knownAt(x, y, z) == bkTable
      of "furnace": hit = sim.world.knownAt(x, y, z) == bkFurnace
      of "tunnel": hit = sim.world.knownAt(x, y, z) == bkTunnel
      else: hit = false
      if not hit:
        continue
      let d = chebyshev(x, y, sim.cog.x, sim.cog.y)
      if d < bestDist or (d == bestDist and (y < bestY or
          (y == bestY and x < bestX))):
        bestDist = d
        bestX = x
        bestY = y
  if bestX < 0:
    return newJNull()
  %*{"x": bestX, "y": bestY, "d": bestDist}

const NearestKeys* = [
  "tree", "water", "stone", "coal_ore", "iron_ore", "diamond_ore", "lava",
  "crafting_table", "furnace", "tunnel", "shaft_down", "shaft_up"
]

proc nearestJson*(sim: SimServer): JsonNode =
  result = newJObject()
  for key in NearestKeys:
    result[key] = sim.nearestOf(key)

proc knownOreJson(sim: SimServer, limit: int): JsonNode =
  ## Up to `limit` known ore cells ACROSS ALL FOUR LEVELS - the cog's
  ## long-term memory of the mine, and what lets it write "there is iron at
  ## z=2 (9,21)" and come back with the right pickaxe.
  var sightings: seq[OreSighting] = @[]
  for z in 0 ..< sim.world.levelCount:
    for y in 0 ..< sim.world.levelSize:
      for x in 0 ..< sim.world.levelSize:
        if not sim.world.isSeen(x, y, z):
          continue
        let known = sim.world.knownAt(x, y, z)
        if known notin {bkCoalOre, bkIronOre, bkDiamondOre}:
          continue
        var sighting = OreSighting(
          what: (case known
                 of bkCoalOre: "coal_ore"
                 of bkIronOre: "iron_ore"
                 else: "diamond_ore"),
          z: z, x: x, y: y,
          seenTick: int(sim.world.seenTick[sim.world.cellIndex(x, y, z)]))
        if z == sim.cog.z:
          sighting.hasDist = true
          sighting.dist = chebyshev(x, y, sim.cog.x, sim.cog.y)
        sightings.add(sighting)
  sightings.sort(proc (a, b: OreSighting): int =
    if a.z != b.z: return cmp(a.z, b.z)
    if a.hasDist and b.hasDist and a.dist != b.dist: return cmp(a.dist, b.dist)
    if a.hasDist != b.hasDist: return (if a.hasDist: -1 else: 1)
    if a.y != b.y: return cmp(a.y, b.y)
    cmp(a.x, b.x))
  result = newJArray()
  for i, sighting in sightings:
    if i >= limit:
      break
    result.add(%*{
      "what": sighting.what,
      "z": sighting.z,
      "x": sighting.x,
      "y": sighting.y,
      "d": (if sighting.hasDist: %sighting.dist else: newJNull()),
      "seen_tick": sighting.seenTick
    })

proc columnJson(sim: SimServer): JsonNode =
  ## Whether the cog has ever stood on each level, and whether THIS exact
  ## (x, y) has a shaft connecting downward. It is how the cog knows it can
  ## `climb_up` without guessing.
  result = newJArray()
  for z in 0 ..< sim.world.levelCount:
    result.add(%*{
      "z": z,
      "label": levelLabel(z),
      "visited": z <= sim.deepestLevel,
      "shaft_here": sim.world.hasShaftDown(sim.cog.x, sim.cog.y, z)
    })

proc milestonesJson(sim: SimServer): JsonNode =
  var
    unlocked = newJArray()
    locked = newJArray()
    next = ""
  for m in Milestone:
    if sim.ledger.unlocked[m]:
      unlocked.add(%*{"id": $m, "tick": sim.ledger.tick[m],
        "points": milestonePoints(m)})
    else:
      locked.add(%($m))
      if next.len == 0:
        next = $m
  %*{
    "count": sim.ledger.milestonesReached(),
    "of": ord(high(Milestone)) + 1,
    "next": next,
    "unlocked": unlocked,
    "locked": locked
  }

proc lastPlanJson(sim: SimServer): JsonNode =
  var
    executed = newJArray()
    blocked = newJArray()
  for act in sim.lastPlan.executed:
    executed.add(%act)
  for entry in sim.lastPlan.blocked:
    blocked.add(%*{"act": entry.act, "why": entry.why})
  %*{
    "executed": executed,
    "truncated": sim.lastPlan.truncated,
    "dropped": sim.lastPlan.dropped,
    "unreachable": sim.lastPlan.unreachable,
    "blocked": blocked,
    "interrupted": sim.lastPlan.interrupted
  }

proc observationJson*(sim: SimServer, turnIndex: int,
    includeNotes: bool): JsonNode =
  ## The whole observation. Mirrored (minus `notes`) into the replay's
  ## `directive` record, so the replay explains every decision.
  let
    ahead = sim.cog.aheadCell()
    aheadBlock = sim.world.at(ahead.x, ahead.y, ahead.z)
    belowKnown = sim.cog.z + 1 < sim.world.levelCount and
      sim.world.isSeen(sim.cog.x, sim.cog.y, sim.cog.z + 1)
  var view = newJArray()
  for row in sim.viewRows():
    view.add(%row)
  var region = newJArray()
  for row in sim.world.regionMap(sim.cog.z, sim.config.regionSize,
      sim.cog.x, sim.cog.y):
    region.add(%row)
  var levelLabels = newJArray()
  for z in 0 ..< sim.world.levelCount:
    levelLabels.add(%levelLabel(z))
  var inventory = newJObject()
  for item in Item:
    inventory[$item] = %sim.cog.inventory[item]
  var tools = newJObject()
  for tool in Tool:
    tools[$tool] = %sim.cog.tools[tool]

  result = %*{
    "you": seatAlias(0),
    "turn": turnIndex,
    "tick": sim.gameTicksElapsed(),
    "ticks_left": sim.ticksLeft(),
    "turns_left": sim.turnsLeft(),
    "world": {
      "levels": sim.world.levelCount,
      "size": sim.world.levelSize,
      "view": 2 * viewRadius(sim.config, sim.cog.z) + 1,
      "region": sim.config.regionSize,
      "level_labels": levelLabels,
      "legend": legendJson()
    },
    "agent": {
      "x": sim.cog.x, "y": sim.cog.y, "z": sim.cog.z,
      "level_label": levelLabel(sim.cog.z),
      "facing": $sim.cog.facing,
      "tier": sim.cog.tier(),
      "ahead": {
        "glyph": $aheadBlock.glyph(),
        "what": $aheadBlock,
        "x": ahead.x, "y": ahead.y,
        "mineable_by_you": aheadBlock.mineTier() >= 0 and
          sim.cog.tier() >= aheadBlock.mineTier()
      },
      "below": (
        if belowKnown:
          %*{"known": true,
             "what": $sim.world.knownAt(sim.cog.x, sim.cog.y, sim.cog.z + 1)}
        else:
          %*{"known": false})
    },
    "inventory": inventory,
    "tools": tools,
    "near": {
      "table": sim.world.adjacentHas(sim.cog, bkTable),
      "furnace": sim.world.adjacentHas(sim.cog, bkFurnace)
    },
    "view": view,
    "region": region,
    "nearest": sim.nearestJson(),
    "known_ore": sim.knownOreJson(24),
    "column": sim.columnJson(),
    "milestones": sim.milestonesJson(),
    "last_plan": sim.lastPlanJson()
  }
  if includeNotes:
    result["notes"] = %sim.lastPlan.notes
