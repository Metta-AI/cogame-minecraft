## The two scripted baselines, both shipped as league fillers. `miner` is also
## the SERVER-SIDE FALLBACK: the decision engine imports `minerPlan` rather
## than duplicating it, so the fallback and the published baseline cannot
## drift.
##
## Both emit the SAME reply object an LLM does, through the same validator,
## which is what makes the bounded-orders test meaningful. Neither ever emits
## `say` or `notes` - a baseline that narrated would make the feed lie about
## which seats are LLMs.

import std/[strutils]

import sim, directives

type
  Baseline* = enum
    blMiner = "miner"
    blScrounger = "scrounger"

  BaselineParams* = object
    ## Like the starter's `DefaultBaselineParams` (`src/ctf/baselines.nim:38`),
    ## the tunables are a parameter object chosen by `tools/tune_baselines.nim`
    ## and pinned by `tools/ci/baseline_tuning.json`, not guessed.
    woodPlanks*: int      ## planks to leave the surface with
    woodSticks*: int      ## sticks to leave the surface with
    stoneCobble*: int     ## cobblestone to leave y=48 with
    stoneCoal*: int       ## coal to leave y=48 with
    sweepLength*: int     ## tunnel length of one sweep
    sweepTurns*: int      ## sweeps before rotating the direction
    latticeSpacing*: int  ## rows between parallel corridors
    valueFirst*: bool     ## break ore ties by value before distance

  BaselineState* = object
    ## Carried between turns by the seat. Deterministic; no randomness.
    sweep*: Facing
    sweepCount*: int
    turnIndex*: int
    lastLevel*: int
    sweptOnLevel*: bool

const DefaultBaselineParams* = BaselineParams(
  ## The SWEPT pick, not a guess: `tools/tune_baselines.nim` evaluated 216
  ## candidates over 40 standard + 40 deepcut seeds and this one scored
  ## highest. `tools/ci/baseline_tuning.json` records it and
  ## `tests/test_minecraft_driver.nim` asserts the two still agree.
  woodPlanks: 8,
  woodSticks: 4,
  stoneCobble: 12,
  stoneCoal: 3,
  sweepLength: 9,
  sweepTurns: 3,
  latticeSpacing: 2,
  valueFirst: true
)

proc parseBaseline*(text: string): Baseline =
  ## Anything unrecognised is the published default (the starter's rule).
  case text.strip().toLowerAscii()
  of "scrounger": blScrounger
  else: blMiner

proc initBaselineState*(): BaselineState =
  result.sweep = fcEast
  result.sweepCount = 0
  result.turnIndex = 0
  result.lastLevel = 0
  result.sweptOnLevel = false

proc rotate(facing: Facing): Facing =
  case facing
  of fcEast: fcSouth
  of fcSouth: fcWest
  of fcWest: fcNorth
  of fcNorth: fcEast

proc perpendicular(facing: Facing): Facing =
  case facing
  of fcEast, fcWest: fcSouth
  of fcNorth, fcSouth: fcEast

proc primitiveAct(primitive: Primitive, n = 1): PlanAction =
  PlanAction(kind: akPrimitive, primitive: primitive, n: n)

proc moveAct(facing: Facing, n: int): PlanAction =
  PlanAction(kind: akMove, facing: facing, n: n)

proc tunnelAct(facing: Facing, n: int): PlanAction =
  PlanAction(kind: akTunnel, facing: facing, n: n)

proc gotoAct(x, y: int): PlanAction =
  PlanAction(kind: akGoto, x: x, y: y, n: 1)

proc nearestKnown(sim: SimServer, kind: Block): tuple[found: bool, x: int,
    y: int, d: int] =
  ## Nearest KNOWN cell of one block on the cog's own level, ties by (y, x).
  result = (false, 0, 0, 0)
  var best = high(int)
  let z = sim.cog.z
  for y in 0 ..< sim.world.levelSize:
    for x in 0 ..< sim.world.levelSize:
      if not sim.world.isSeen(x, y, z):
        continue
      if sim.world.knownAt(x, y, z) != kind:
        continue
      let d = chebyshev(x, y, sim.cog.x, sim.cog.y)
      if d < best:
        best = d
        result = (true, x, y, d)

proc lavaAdjacent(sim: SimServer): tuple[found: bool, x: int, y: int,
    d: int] =
  let near = sim.nearestKnown(bkLava)
  if near.found and near.d <= 1:
    return near
  (false, 0, 0, 0)

proc safestStep(sim: SimServer): tuple[found: bool, facing: Facing] =
  ## The known traversable neighbour that maximises the Chebyshev distance to
  ## every known lava cell on this level, ties by the neighbour order.
  ##
  ## `found` is false when the cog is boxed in: with no traversable neighbour
  ## there is no safe step, and a default facing here would be a step in an
  ## arbitrary direction - straight into the lava, if that is what is in
  ## front. Standing still costs a tick; the other one ends the run.
  var
    best = fcNorth
    bestScore = -1
  for facing in Neighbours:
    let
      nx = sim.cog.x + facing.dx()
      ny = sim.cog.y + facing.dy()
    if not sim.world.knownTraversable(nx, ny, sim.cog.z):
      continue
    var score = high(int)
    for y in 0 ..< sim.world.levelSize:
      for x in 0 ..< sim.world.levelSize:
        if not sim.world.isSeen(x, y, sim.cog.z):
          continue
        if sim.world.knownAt(x, y, sim.cog.z) != bkLava:
          continue
        score = min(score, chebyshev(nx, ny, x, y))
    if score == high(int):
      score = 99
    if score > bestScore:
      bestScore = score
      best = facing
  (bestScore >= 0, best)

proc craftAction(sim: SimServer, params: BaselineParams): tuple[has: bool,
    action: PlanAction] =
  ## Rule 2: craft whatever is affordable right now, in ladder order, first
  ## match. Shared by both baselines - `scrounger` uses exactly this test with
  ## no lookahead.
  let
    cog = sim.cog
    nearTable = sim.world.adjacentHas(cog, bkTable)
    nearFurnace = sim.world.adjacentHas(cog, bkFurnace)
  if cog.inventory[itLog] >= 1 and cog.inventory[itPlanks] < params.woodPlanks:
    return (true, primitiveAct(pCraftPlanks, min(3, cog.inventory[itLog])))
  if cog.inventory[itPlanks] >= 2 and cog.inventory[itStick] < params.woodSticks:
    return (true, primitiveAct(pCraftSticks))
  let pickaxeAffordable =
    (not cog.tools[tlWooden] and cog.inventory[itPlanks] >= 3 and
      cog.inventory[itStick] >= 2) or
    (not cog.tools[tlStone] and cog.inventory[itCobblestone] >= 3 and
      cog.inventory[itStick] >= 2) or
    (not cog.tools[tlIron] and cog.inventory[itIronIngot] >= 3 and
      cog.inventory[itStick] >= 2)
  if not nearTable and cog.inventory[itPlanks] >= 4 and pickaxeAffordable:
    return (true, primitiveAct(pPlaceTable))
  if nearTable and not cog.tools[tlWooden] and cog.inventory[itPlanks] >= 3 and
      cog.inventory[itStick] >= 2:
    return (true, primitiveAct(pCraftWoodenPickaxe))
  if nearTable and not cog.tools[tlStone] and
      cog.inventory[itCobblestone] >= 3 and cog.inventory[itStick] >= 2:
    return (true, primitiveAct(pCraftStonePickaxe))
  if cog.inventory[itCobblestone] >= 8 and not nearFurnace and
      cog.inventory[itRawIron] >= 1:
    return (true, primitiveAct(pPlaceFurnace))
  if nearFurnace and cog.inventory[itRawIron] >= 1 and
      cog.inventory[itCoal] >= 1 and cog.inventory[itIronIngot] < 3:
    return (true, primitiveAct(pSmeltIron,
      min(3, min(cog.inventory[itRawIron], cog.inventory[itCoal]))))
  if nearTable and not cog.tools[tlIron] and cog.inventory[itIronIngot] >= 3 and
      cog.inventory[itStick] >= 2:
    return (true, primitiveAct(pCraftIronPickaxe))
  (false, primitiveAct(pNoop))

proc targetOre(sim: SimServer, params: BaselineParams): tuple[found: bool,
    x: int, y: int] =
  ## The highest-value known ore ON THIS LEVEL the cog has the tier for
  ## (diamond > iron > coal), nearest first, ties by (y, x).
  let tier = sim.cog.tier()
  var order: seq[Block] = @[]
  if tier >= 3: order.add(bkDiamondOre)
  if tier >= 2: order.add(bkIronOre)
  if tier >= 1: order.add(bkCoalOre)
  if params.valueFirst:
    for kind in order:
      let near = sim.nearestKnown(kind)
      if near.found:
        return (true, near.x, near.y)
    return (false, 0, 0)
  var
    best = high(int)
    bestX = 0
    bestY = 0
    found = false
  for kind in order:
    let near = sim.nearestKnown(kind)
    if near.found and near.d < best:
      best = near.d
      bestX = near.x
      bestY = near.y
      found = true
  (found, bestX, bestY)

proc levelExitMet(sim: SimServer, params: BaselineParams): bool =
  let cog = sim.cog
  case cog.z
  of 0:
    cog.tools[tlWooden] and cog.inventory[itPlanks] >= params.woodPlanks and
      cog.inventory[itStick] >= params.woodSticks
  of 1:
    cog.tools[tlStone] and
      cog.inventory[itCobblestone] >= params.stoneCobble and
      cog.inventory[itCoal] >= params.stoneCoal
  of 2:
    cog.tools[tlIron]
  else:
    false

proc sweepPlan(sim: SimServer, params: BaselineParams,
    state: var BaselineState): seq[PlanAction] =
  ## Rule 6: cut a straight corridor, and step `latticeSpacing` rows sideways
  ## whenever a corridor on this level has already been cut, so the sweeps
  ## form a lattice rather than one hole.
  result = @[]
  if state.sweepCount >= params.sweepTurns:
    state.sweep = rotate(state.sweep)
    state.sweepCount = 0
  if state.sweptOnLevel:
    result.add(moveAct(perpendicular(state.sweep), params.latticeSpacing))
  result.add(tunnelAct(state.sweep, params.sweepLength))
  inc state.sweepCount
  state.sweptOnLevel = true

proc minerPlan*(sim: SimServer, params: BaselineParams,
    state: var BaselineState): Plan =
  ## The deterministic priority ladder. Every turn, the FIRST matching rule
  ## wins and emits at most `maxActionsPerTurn` actions.
  ##
  ## `miner` never routes through lava (lava is not traversable to the BFS),
  ## never digs down without the tier the level below needs (rule 5's exit
  ## conditions guarantee it), and never walks back up a shaft - which is
  ## exactly the floor a champion has to beat.
  result.source = dsScripted
  result.actions = @[]
  if sim.cog.z != state.lastLevel:
    state.lastLevel = sim.cog.z
    state.sweptOnLevel = false
    state.sweepCount = 0
  inc state.turnIndex

  # 1. Lava adjacent.
  let lava = sim.lavaAdjacent()
  if lava.found:
    let ahead = sim.cog.aheadCell()
    if ahead.x == lava.x and ahead.y == lava.y and
        sim.cog.inventory[itCobblestone] >= 1:
      result.actions.add(primitiveAct(pPlaceBlock))
    else:
      let away = sim.safestStep()
      if away.found:
        result.actions.add(moveAct(away.facing, 1))
        result.actions.add(moveAct(away.facing, 2))
      else:
        ## Boxed in beside lava: mine a way out of the rock rather than step
        ## into the one cell that is walkable.
        result.actions.add(primitiveAct(pMine, 2))
    return

  # 2. Craft whatever is affordable right now, then fall through to rule 6.
  let craft = sim.craftAction(params)
  if craft.has:
    result.actions.add(craft.action)

  # 3. Wood. Wood only exists on the surface, so a wood-poor start is fatal.
  if sim.cog.z == 0 and sim.cog.inventory[itLog] < 2:
    let tree = sim.nearestKnown(bkTree)
    if tree.found:
      result.actions.add(gotoAct(tree.x, tree.y))
      result.actions.add(primitiveAct(pMine, 2))
      for action in sim.sweepPlan(params, state):
        result.actions.add(action)
      return

  # 4. Target ore - but only while this level still has something the cog
  #    needs. The instant the exit condition is met, rule 5 wins: a level a
  #    cog has finished is a level it should not be standing on, and mining
  #    one more coal seam there is a tick it does not get back.
  let exitMet = sim.levelExitMet(params)
  let ore = if exitMet: (found: false, x: 0, y: 0)
            else: sim.targetOre(params)
  if ore.found:
    result.actions.add(gotoAct(ore.x, ore.y))
    result.actions.add(primitiveAct(pMine, 2))
    for action in sim.sweepPlan(params, state):
      result.actions.add(action)
    return

  # 5. Descend. A level the cog has finished is a level it should not be
  #    standing on.
  if sim.cog.z < sim.world.levelCount - 1 and exitMet:
    result.actions.add(primitiveAct(pDigDown))
    result.actions.add(tunnelAct(state.sweep, 6))
    state.sweptOnLevel = false
    return

  # 6. Sweep.
  for action in sim.sweepPlan(params, state):
    result.actions.add(action)

proc lavaFreeRay(sim: SimServer, facing: Facing, cells: int): bool =
  ## Is the straight ray ahead free of KNOWN lava for `cells` steps? The only
  ## thing in this world that can end a run is lava, and `scrounger` has no
  ## memory and no BFS - but "walk into a fire you can see" is not reactivity,
  ## it is a bug, so even the reactive control looks one ray ahead.
  for step in 1 .. cells:
    let
      x = sim.cog.x + facing.dx() * step
      y = sim.cog.y + facing.dy() * step
    if not sim.world.inBounds(x, y, sim.cog.z):
      return true
    if sim.world.isSeen(x, y, sim.cog.z) and
        sim.world.knownAt(x, y, sim.cog.z) == bkLava:
      return false
  true

proc scroungerPlan*(sim: SimServer, params: BaselineParams,
    state: var BaselineState): Plan =
  ## The reactive control: no memory, no BFS, no ore targeting. It chops a
  ## tree by accident, crafts when it happens to be able to, digs down on a
  ## timer, and reliably stalls around the stone pickaxe. It is the control
  ## that answers "did the LLM actually plan?"
  result.source = dsScripted
  result.actions = @[]
  inc state.turnIndex
  let craft = sim.craftAction(params)
  if craft.has:
    result.actions.add(craft.action)
  if sim.cog.tier() >= 1 and (sim.gameTicksElapsed() mod 120) <
      sim.config.turnTicks:
    result.actions.add(primitiveAct(pDigDown))
  var facing = state.sweep
  for _ in 0 ..< 4:
    if sim.lavaFreeRay(facing, sim.config.turnTicks):
      break
    facing = rotate(facing)
  while result.actions.len < sim.config.maxActionsPerTurn:
    result.actions.add(primitiveAct(pMine, 2))
    if result.actions.len >= sim.config.maxActionsPerTurn:
      break
    result.actions.add(moveAct(facing, 1))
  state.sweep = rotate(state.sweep)

proc baselinePlan*(sim: SimServer, kind: Baseline, params: BaselineParams,
    state: var BaselineState): Plan =
  case kind
  of blMiner: minerPlan(sim, params, state)
  of blScrounger: scroungerPlan(sim, params, state)
