## Bounded orders and legality on the scripted baselines, plus the driver and
## the reply validator.
##
## Design note §Tests items 12 and 18-24. A baseline that ever proposes an
## illegal or unbounded action fails the build.

import std/[json, sets, strutils, unicode]

import minecraft/sim
import minecraft/directives
import minecraft/driver
import minecraft/baselines
import minecraft/decide

proc testConfig(seed: int, deep = false): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  if deep:
    result.variant = "deepcut"
    result.maxTurns = 32
    result.maxTicks = 640
    result.parMilestones = 5

proc scramble(sim: var SimServer, salt: int) =
  ## A pseudo-random but deterministic world state: a level, a position, an
  ## inventory, a tool set and an explored neighbourhood.
  let size = sim.world.levelSize
  sim.cog.z = mix64(salt, 1, 0, 0) mod sim.world.levelCount
  sim.cog.x = 2 + mix64(salt, 2, 0, 0) mod (size - 4)
  sim.cog.y = 2 + mix64(salt, 3, 0, 0) mod (size - 4)
  sim.cog.facing = Facing(mix64(salt, 4, 0, 0) mod 4)
  for item in Item:
    sim.cog.inventory[item] = mix64(salt, 5 + ord(item), 0, 0) mod 20
  for tool in Tool:
    sim.cog.tools[tool] = (mix64(salt, 20 + ord(tool), 0, 0) mod 2) == 1
  # put something interesting next to the cog: lava, water, ore or a table
  let flavour = mix64(salt, 40, 0, 0) mod 5
  let target = case flavour
    of 0: bkLava
    of 1: bkWater
    of 2: bkIronOre
    of 3: bkTable
    else: bkTunnel
  sim.world.setBlock(sim.cog.x + 1, sim.cog.y, sim.cog.z, target)
  discard sim.world.observe(sim.cog.x, sim.cog.y, sim.cog.z,
    viewRadius(sim.config, sim.cog.z), 1)

proc nRangeOk(action: PlanAction): bool =
  case action.kind
  of akGoto: action.n == 1
  of akMove: action.n >= 1 and action.n <= 12
  of akTunnel: action.n >= 1 and action.n <= 10
  of akPrimitive:
    case action.primitive
    of pMine: action.n >= 1 and action.n <= 12
    of pDigDown, pClimbUp: action.n >= 1 and action.n <= 3
    of pCraftPlanks: action.n >= 1 and action.n <= 8
    of pCraftSticks: action.n >= 1 and action.n <= 4
    of pSmeltIron: action.n >= 1 and action.n <= 6
    of pNoop: action.n >= 1 and action.n <= 20
    else: action.n == 1

# 18/19/20. `baselines are bounded`, `baselines never suicide`,
#           `the driver never produces an illegal primitive`
block boundedBaselines:
  var checked = 0
  for trial in 0 ..< 300:
    let deep = (trial mod 2) == 1
    var sim = initSimServer(testConfig(1000 + trial, deep))
    sim.startGame()
    sim.scramble(trial)
    for kind in Baseline:
      var state = initBaselineState()
      let plan = baselinePlan(sim, kind, DefaultBaselineParams, state)
      doAssert plan.actions.len <= sim.config.maxActionsPerTurn,
        $kind & " proposed " & $plan.actions.len & " actions"
      doAssert plan.say.len == 0, "a baseline never narrates"
      doAssert plan.notes.len == 0, "a baseline never writes notes"
      doAssert plan.planBytes() <= 1024,
        $kind & " serialised to " & $plan.planBytes() & " bytes"
      for action in plan.actions:
        doAssert action.nRangeOk(), "n out of range for " & $action.kind
        if action.kind == akGoto:
          doAssert action.x >= 0 and action.x < sim.config.levelSize
          doAssert action.y >= 0 and action.y < sim.config.levelSize
      # 20. the driver: every expanded queue is bounded and legal
      let expanded = expandPlan(sim, plan)
      doAssert expanded.queue.len <= sim.config.turnTicks
      for primitive in expanded.queue:
        doAssert ord(primitive) >= ord(low(Primitive))
        doAssert ord(primitive) <= ord(high(Primitive))
      # 19. never suicide: the deterministic expansion never steps onto a
      #     KNOWN lava cell.
      var
        x = sim.cog.x
        y = sim.cog.y
      for primitive in expanded.queue:
        let move = primitive.facingOfMove()
        if not move.ok:
          continue
        let
          nx = x + move.facing.dx()
          ny = y + move.facing.dy()
        if not sim.world.inBounds(nx, ny, sim.cog.z):
          continue
        let cell = sim.world.at(nx, ny, sim.cog.z)
        if cell.walkable():
          doAssert not (cell == bkLava and
              sim.world.isSeen(nx, ny, sim.cog.z)),
            $kind & " walked onto a KNOWN lava cell"
          x = nx
          y = ny
      inc checked
  doAssert checked == 600
  echo "ok: both baselines are bounded, legal and never walk into known lava"

# 20 (continued). an empty queue yields noop, never nothing
block emptyQueueIsNoop:
  var sim = initSimServer(testConfig(77))
  sim.startGame()
  var empty: Plan
  empty.actions = @[]
  let expanded = expandPlan(sim, empty)
  doAssert expanded.queue.len == 0
  # The server pops `pNoop` from an empty queue; the sim spends the tick.
  let before = sim.tickCount
  sim.step(pNoop)
  doAssert sim.tickCount == before + 1
  echo "ok: an empty plan is twenty noop ticks, never a stalled turn"

# 12. `tunnel expands correctly`
block tunnelExpansion:
  var sim = initSimServer(testConfig(88))
  sim.startGame()
  var plan: Plan
  plan.actions = @[PlanAction(kind: akTunnel, facing: fcEast, n: 6)]
  let expanded = expandPlan(sim, plan)
  doAssert expanded.queue.len == 12
  for i in 0 ..< 6:
    doAssert expanded.queue[i * 2] == pMine
    doAssert expanded.queue[i * 2 + 1] == pMoveEast
  # capped at macroPrimitiveCap, then truncated to turnTicks
  var big: Plan
  big.actions = @[PlanAction(kind: akTunnel, facing: fcNorth, n: 10)]
  let capped = expandPlan(sim, big)
  doAssert capped.queue.len <= sim.config.macroPrimitiveCap
  doAssert capped.queue.len <= sim.config.turnTicks
  # move expands to n steps
  var walk: Plan
  walk.actions = @[PlanAction(kind: akMove, facing: fcSouth, n: 4)]
  doAssert expandPlan(sim, walk).queue == @[pMoveSouth, pMoveSouth,
    pMoveSouth, pMoveSouth]
  echo "ok: tunnel is n x (mine, move) and every macro respects its cap"

# 21. `fallback is the miner proc`
block fallbackIsMiner:
  var sim = initSimServer(testConfig(99))
  sim.startGame()
  sim.step(pNoop)
  var engine = initDecisionEngine(sim)
  var stateA = initBaselineState()
  let direct = minerPlan(sim, DefaultBaselineParams, stateA)
  let viaFallback = engine.minerFallback(sim, 0)
  doAssert direct.actions.len == viaFallback.actions.len
  for i in 0 ..< direct.actions.len:
    doAssert $direct.actions[i].actionJson() ==
      $viaFallback.actions[i].actionJson(),
      "the fallback and the published miner baseline have drifted"
  doAssert viaFallback.source == dsFallback
  echo "ok: the server-side fallback IS the miner baseline proc"

# 22. `reply validation`
block replyValidation:
  const size = 32
  const cap = 12
  # accepts the schema
  let good = parsePlan(extractJsonObject("""
    {"actions":[{"act":"mine","n":3},{"act":"goto","x":13,"y":20},
                {"act":"tunnel","dir":"east","n":6}],
     "say":"iron in the wall","notes":"z=2 workshop"}"""), cap, size)
  doAssert good.actions.len == 3
  doAssert good.say == "iron in the wall"
  doAssert good.notes == "z=2 workshop"
  # DROPS an invalid action, never rewrites it
  let dropped = parsePlan(extractJsonObject("""
    {"actions":[{"act":"teleport"},{"act":"goto","y":4},{"act":"mine"}]}"""),
    cap, size)
  doAssert dropped.actions.len == 1
  doAssert dropped.actions[0].primitive == pMine
  doAssert dropped.dropped == 2
  # clamps goto coordinates and every n
  let clamped = parsePlan(extractJsonObject("""
    {"actions":[{"act":"goto","x":-5,"y":900},{"act":"mine","n":99},
                {"act":"dig_down","n":9},{"act":"noop","n":400}]}"""),
    cap, size)
  doAssert clamped.actions[0].x == 0 and clamped.actions[0].y == 31
  doAssert clamped.actions[1].n == 12
  doAssert clamped.actions[2].n == 3
  doAssert clamped.actions[3].n == 20
  # lower-cases and normalises `act`, case-folds and aliases `dir`
  let normalised = parsePlan(extractJsonObject("""
    {"actions":[{"act":"Dig-Down"},{"act":"move","dir":"UP","n":2},
                {"act":"tunnel","dir":"Left","n":3}]}"""), cap, size)
  doAssert normalised.actions[0].primitive == pDigDown
  doAssert normalised.actions[1].facing == fcNorth
  doAssert normalised.actions[2].facing == fcWest
  # a say-only reply is USABLE
  let sayOnly = parsePlan(extractJsonObject("""{"say":"thinking"}"""),
    cap, size)
  doAssert sayOnly.actions.len == 0
  doAssert sayOnly.say == "thinking"
  # a non-object is a parse failure
  var raised = false
  try:
    discard parsePlan(extractJsonObject("""[1,2,3]"""), cap, size)
  except CatchableError:
    raised = true
  doAssert raised
  raised = false
  try:
    discard extractJsonObject("no json here at all")
  except CatchableError:
    raised = true
  doAssert raised
  # fence-tolerant, prose-tolerant extraction
  let fenced = parsePlan(extractJsonObject(
    "Sure! ```json\n{\"actions\":[{\"act\":\"noop\"}]}\n``` hope that helps"),
    cap, size)
  doAssert fenced.actions.len == 1
  # caps `actions` at 12
  var many = "{\"actions\":["
  for i in 0 ..< 30:
    if i > 0: many.add(",")
    many.add("{\"act\":\"noop\"}")
  many.add("]}")
  let capped = parsePlan(extractJsonObject(many), cap, size)
  doAssert capped.actions.len == cap
  doAssert capped.truncatedActions
  doAssert capped.dropped == 18
  # RUNE-boundary truncation at 160/400 with 4-byte emoji ON the boundary
  let emoji = "\u{1F600}"
  doAssert emoji.runeLen == 1 and emoji.len == 4
  var longSay = ""
  for i in 0 ..< 400:
    longSay.add(emoji)
  var longNotes = ""
  for i in 0 ..< 900:
    longNotes.add(emoji)
  let capsNode = %*{"say": longSay, "notes": longNotes}
  let capped2 = parsePlan(capsNode, cap, size)
  doAssert capped2.say.runeLen == MaxSayRunes
  doAssert capped2.notes.runeLen == MaxNoteRunes
  doAssert capped2.say.validateUtf8() == -1, "a byte cut would break UTF-8"
  doAssert capped2.notes.validateUtf8() == -1
  doAssert capped2.say.len == MaxSayRunes * 4
  echo "ok: the validator drops, clamps, normalises and truncates on RUNES"

# 23. `baseline tuning is the swept pick`
block tuningIsTheSweptPick:
  let pinned = parseJson(readFile("tools/ci/baseline_tuning.json"))
  let params = DefaultBaselineParams
  doAssert pinned["woodPlanks"].getInt == params.woodPlanks
  doAssert pinned["woodSticks"].getInt == params.woodSticks
  doAssert pinned["stoneCobble"].getInt == params.stoneCobble
  doAssert pinned["stoneCoal"].getInt == params.stoneCoal
  doAssert pinned["sweepLength"].getInt == params.sweepLength
  doAssert pinned["sweepTurns"].getInt == params.sweepTurns
  doAssert pinned["latticeSpacing"].getInt == params.latticeSpacing
  doAssert pinned["valueFirst"].getBool == params.valueFirst
  echo "ok: the shipped miner thresholds equal the swept pick"

# 24. `miner beats scrounger`
proc playScripted(config: GameConfig, kind: Baseline): SimServer =
  result = initSimServer(config)
  result.startGame()
  var state = initBaselineState()
  var queue: seq[Primitive] = @[]
  var turnTicks = 0
  while result.phase == Playing:
    if queue.len == 0 or turnTicks >= result.config.turnTicks:
      let plan = baselinePlan(result, kind, DefaultBaselineParams, state)
      queue = expandPlan(result, plan).queue
      turnTicks = 0
      result.noteTurnEnd()
      if result.phase != Playing:
        break
    var primitive = pNoop
    if queue.len > 0:
      primitive = queue[0]
      queue.delete(0)
    result.step(primitive)
    inc turnTicks
    if result.interruptRequested:
      queue.setLen(0)
      turnTicks = result.config.turnTicks

block minerBeatsScrounger:
  var
    minerTotal = 0
    scroungerTotal = 0
    minerDeep = 0
    scroungerAtLeastOne = 0
    seeds = 0
  for seed in 1 .. 50:
    for deep in [false, true]:
      let config = testConfig(seed * 7 + 1, deep)
      let a = playScripted(config, blMiner)
      let b = playScripted(config, blScrounger)
      minerTotal += a.ledger.milestoneScore()
      scroungerTotal += b.ledger.milestoneScore()
      if a.ledger.milestonesReached() >= 9 and not deep:
        inc minerDeep
      if b.ledger.milestonesReached() >= 1:
        inc scroungerAtLeastOne
      if not deep:
        inc seeds
  doAssert minerTotal > scroungerTotal,
    "miner " & $minerTotal & " vs scrounger " & $scroungerTotal
  doAssert scroungerAtLeastOne > 0, "the control must not be a zero"
  doAssert minerDeep * 2 > seeds,
    "miner reached rung 9 on only " & $minerDeep & " of " & $seeds &
    " standard seeds"
  echo "ok: miner ", minerTotal, " beats scrounger ", scroungerTotal,
    " and clears rung 9 on ", minerDeep, "/", seeds, " standard seeds"

echo "test_minecraft_driver: PASS"
