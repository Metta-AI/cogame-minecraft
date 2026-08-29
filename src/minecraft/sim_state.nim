## The simulation server: the whole physics of the game and nothing else.
##
## The tick loop is the design note's numbered resolution order, in order, and
## it is the ONLY thing that mutates the world. Forked from
## `src/ctf/sim_state.nim` for `gameHash` / `mixHash` / `emitEvent` / the lobby
## countdown, with paintbot's arena, guns, paint and teams replaced by the four
## stacked cell grids this game is about.
##
## DETERMINISM. Every quantity is an integer and every generated quantity is a
## read of the pure hash `mix64(seed, salt, ...)`, so the sim is a pure function
## of `(seed, variant, primitive sequence)` and the native and wasm hash chains
## agree by construction.

import std/[strutils]

import sim_types, sim_config, world, agent, milestones

type
  SimEventKind* = enum
    TurnStart, Directive, Fallback, PrimitiveRun, Mine, Craft, Smelt, Place,
    Descend, Ascend, LavaFound, Bridge, BlockedAct, MilestoneHit, Death

  SimEvent* = object
    tick*: int
    kind*: SimEventKind
    what*: string
    why*: string
    x*, y*, z*: int
    amount*: int
    content*: string

  PlayerRecord* = object
    ## One joined seat. `address` is the REAL policy name and lives only here,
    ## in the config JSON and spectator-side - never in an observation.
    address*: string
    joinOrder*: int
    token*: string

  LastPlan* = object
    executed*: seq[string]
    truncated*: bool
    dropped*: int
    unreachable*: int
    blocked*: seq[tuple[act: string, why: string]]
    interrupted*: string
    notes*: string

  SimServer* = object
    config*: GameConfig
    world*: World
    cog*: Cog
    ledger*: MilestoneLedger

    phase*: GamePhase
    tickCount*: int
    gameStartTick*: int
    lobbyTicks*: int
    gameOverTicks*: int
    turnsPlayed*: int

    endRule*: string
    endReason*: string
    deathCause*: string
    stopDetail*: string

    worldHash*: uint64
    interruptRequested*: bool

    blocksMined*: int
    blocksPlaced*: int
    itemsCrafted*: int
    ironSmelted*: int
    shaftsDug*: int
    bridgesPlaced*: int
    coalMined*: int
    ironOreMined*: int
    diamondsMined*: int
    interrupts*: int
    primitivesExecuted*: int
    actionsDropped*: int
    macrosUnreachable*: int
    repliesRepaired*: int
    cellsSeenCount*: int
    deepestLevel*: int
    ticksPerLevel*: seq[int]

    players*: seq[PlayerRecord]
    seatNames*: seq[string]
    seatPolicyKind*: seq[string]
    deadSeats*: seq[bool]
    llmTurns*: seq[int]
    fallbackTurns*: seq[int]

    lastPlan*: LastPlan
    feedDirectives*: seq[string]

    events*: seq[SimEvent]
    collectEvents*: bool
    gameEventLoggingEnabled*: bool

proc emitEvent*(sim: var SimServer, kind: SimEventKind, what = "",
    why = "", x = 0, y = 0, z = 0, amount = 0, content = "") =
  ## Tier-2 analysis stream only. `SimEvent` never enters `gameHash`, so
  ## nothing here can affect determinism.
  if not sim.collectEvents:
    return
  sim.events.add(SimEvent(tick: sim.tickCount, kind: kind, what: what,
    why: why, x: x, y: y, z: z, amount: amount, content: content))

proc cellDigest(x, y, z: int, value: Block, shaft: bool): uint64 {.inline.} =
  ## One cell's contribution to the world digest. The digest is an XOR FOLD of
  ## these, which is what makes the incremental update EXACT: a mutation xors
  ## the old contribution out and the new one in, so the running digest is
  ## always bit-identical to a fresh fold over all 4096 cells (asserted by
  ## tests/test_minecraft_replay.nim). A non-invertible rolling mix would be
  ## cheaper to write and impossible to check.
  uint64(mix64(z * 8191 + 7, x * 131 + 3, y * 17 + 5,
    ord(value) * 2 + (if shaft: 1 else: 0)))

proc foldWorldHash(sim: var SimServer) =
  ## Seeds the digest by folding all four grids and the shaft planes once, at
  ## generation. Every later mutation updates it incrementally.
  var h = 0xCBF29CE484222325'u64
  let size = sim.world.levelSize
  for z in 0 ..< sim.world.levelCount:
    for y in 0 ..< size:
      for x in 0 ..< size:
        let idx = sim.world.cellIndex(x, y, z)
        h = h xor cellDigest(x, y, z, sim.world.cells[idx],
          sim.world.shaftDown[idx])
  sim.worldHash = h

proc noteMutation(sim: var SimServer, x, y, z: int, oldBlock,
    newBlock: Block) {.inline.} =
  let shaft = sim.world.hasShaftDown(x, y, z)
  sim.worldHash = sim.worldHash xor cellDigest(x, y, z, oldBlock, shaft)
  sim.worldHash = sim.worldHash xor cellDigest(x, y, z, newBlock, shaft)

proc noteShaft(sim: var SimServer, x, y, z: int) {.inline.} =
  ## The shaft plane flipped ON at this cell; the block is unchanged.
  let value = sim.world.at(x, y, z)
  sim.worldHash = sim.worldHash xor cellDigest(x, y, z, value, false)
  sim.worldHash = sim.worldHash xor cellDigest(x, y, z, value, true)

proc initSimServer*(config: GameConfig): SimServer =
  result.config = config
  result.world = generateWorld(config)
  result.cog = initCog(result.world.spawnCell())
  result.ledger = initMilestoneLedger()
  result.phase = Lobby
  result.tickCount = 0
  result.gameStartTick = -1
  result.endRule = ""
  result.endReason = ""
  result.deathCause = DeathCauseNone
  result.stopDetail = ""
  result.deepestLevel = 0
  result.ticksPerLevel = newSeq[int](config.levelCount)
  result.players = @[]
  let seats = config.seatCountOf()
  result.seatNames = newSeq[string](seats)
  result.seatPolicyKind = newSeq[string](seats)
  result.deadSeats = newSeq[bool](seats)
  result.llmTurns = newSeq[int](seats)
  result.fallbackTurns = newSeq[int](seats)
  for i in 0 ..< seats:
    result.seatPolicyKind[i] = "scripted"
  result.lastPlan = LastPlan(interrupted: "")
  result.feedDirectives = @[]
  result.events = @[]
  result.foldWorldHash()
  # The cog can see where it is standing before it ever acts.
  result.cellsSeenCount = result.world.observe(result.cog.x, result.cog.y,
    result.cog.z, viewRadius(config, 0), 0)

proc seatCount*(sim: SimServer): int {.inline.} =
  sim.config.seatCountOf()

proc maxTicks*(sim: SimServer): int {.inline.} =
  sim.config.maxTicks

proc gameTicksElapsed*(sim: SimServer): int {.inline.} =
  if sim.gameStartTick < 0: 0 else: max(0, sim.tickCount - sim.gameStartTick)

proc ticksLeft*(sim: SimServer): int {.inline.} =
  max(0, sim.config.maxTicks - sim.gameTicksElapsed())

proc turnsLeft*(sim: SimServer): int {.inline.} =
  max(0, sim.config.maxTurns - sim.turnsPlayed)

proc episodeOver*(sim: SimServer): bool {.inline.} =
  sim.phase == GameOver

proc cogAlias*(sim: SimServer, seat: int): string =
  seatAlias(seat)

proc worldDigestFold*(sim: SimServer): uint64 =
  ## A fresh fold over every cell and every shaft plane. The incrementally
  ## maintained `worldHash` is only safe if a test can show the two agree, so
  ## the fold is exported for exactly that test.
  result = 0xCBF29CE484222325'u64
  let size = sim.world.levelSize
  for z in 0 ..< sim.world.levelCount:
    for y in 0 ..< size:
      for x in 0 ..< size:
        let idx = sim.world.cellIndex(x, y, z)
        result = result xor cellDigest(x, y, z, sim.world.cells[idx],
          sim.world.shaftDown[idx])

proc gameHash*(sim: SimServer): uint64 =
  ## Mixed in this fixed order: tick; the cog's (x, y, z, facing); the eight
  ## inventory counts; the three tool bits; the 11-bit milestone mask; then
  ## the rolling world digest.
  result = mixHash(0x9E3779B9'u64, sim.tickCount)
  result = mixHash(result, sim.cog.x)
  result = mixHash(result, sim.cog.y)
  result = mixHash(result, sim.cog.z)
  result = mixHash(result, ord(sim.cog.facing))
  for item in Item:
    result = mixHash(result, sim.cog.inventory[item])
  for tool in Tool:
    result = mixHash(result, (if sim.cog.tools[tool]: 1 else: 0))
  result = mixHash(result, sim.ledger.milestoneScore())
  result = mixHash(result, (if sim.cog.alive: 1 else: 0))
  result = result xor sim.worldHash

proc finishEpisode*(sim: var SimServer, rule: string, reason: string) =
  if sim.phase == GameOver:
    return
  sim.phase = GameOver
  sim.endRule = rule
  sim.endReason = reason
  sim.gameOverTicks = 0

proc evaluateMilestones(sim: var SimServer) =
  ## Every predicate is over SIM STATE. No rung is ever a self-report.
  template unlock(m: Milestone) =
    if sim.ledger.recordMilestone(m, sim.gameTicksElapsed()):
      sim.emitEvent(MilestoneHit, what = $m, amount = milestonePoints(m))
  if sim.cog.inventory[itLog] >= 1: unlock(msLog)
  if sim.cog.inventory[itPlanks] >= 1: unlock(msPlanks)
  if sim.cog.inventory[itCobblestone] >= 1: unlock(msCobblestone)
  if sim.cog.inventory[itRawIron] >= 1: unlock(msIronOre)
  if sim.cog.inventory[itIronIngot] >= 1: unlock(msIronIngot)
  if sim.cog.inventory[itDiamond] >= 1: unlock(msDiamond)
  if sim.cog.tools[tlWooden]: unlock(msWoodenPickaxe)
  if sim.cog.tools[tlStone]: unlock(msStonePickaxe)
  if sim.cog.tools[tlIron]: unlock(msIronPickaxe)
  if not sim.ledger.unlocked[msCraftingTable] or
      not sim.ledger.unlocked[msFurnace]:
    var
      hasTable = false
      hasFurnace = false
    for cell in sim.world.cells:
      if cell == bkTable: hasTable = true
      elif cell == bkFurnace: hasFurnace = true
    if hasTable: unlock(msCraftingTable)
    if hasFurnace: unlock(msFurnace)

proc lavaAdjacentNewlyKnown(sim: SimServer, before: seq[bool]): bool =
  ## Did this tick make a `lava` cell within Chebyshev 1 of the cog NEWLY
  ## known? Lava is the only thing in this world that can end a run, so
  ## finding some next to you throws away the rest of your plan.
  for dz in -1 .. 1:
    let z = sim.cog.z + dz
    if z < 0 or z >= sim.world.levelCount:
      continue
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        if dz != 0 and (dx != 0 or dy != 0):
          continue
        let
          x = sim.cog.x + dx
          y = sim.cog.y + dy
        if not sim.world.inBounds(x, y, z):
          continue
        let idx = sim.world.cellIndex(x, y, z)
        if sim.world.cells[idx] != bkLava:
          continue
        if sim.world.seen[idx] and not before[idx]:
          return true
  false

proc startGame*(sim: var SimServer) =
  sim.phase = Playing
  sim.gameStartTick = sim.tickCount
  sim.lobbyTicks = 0

proc step*(sim: var SimServer, primitive: Primitive) =
  ## ONE tick. The numbered resolution order of the design note, in order.
  inc sim.tickCount
  case sim.phase
  of Lobby:
    inc sim.lobbyTicks
    return
  of GameOver:
    inc sim.gameOverTicks
    return
  of Playing:
    discard

  let seenBefore = sim.world.seen

  # 3. Apply the primitive.
  let outcome = applyPrimitive(sim.world, sim.cog, primitive, sim.gameTicksElapsed())
  inc sim.primitivesExecuted
  sim.emitEvent(PrimitiveRun, what = $primitive)
  if outcome.mined:
    inc sim.blocksMined
    sim.noteMutation(outcome.minedX, outcome.minedY, outcome.minedZ,
      outcome.minedBlock, outcome.minedBlock.becomes())
    case outcome.minedBlock
    of bkCoalOre: inc sim.coalMined
    of bkIronOre: inc sim.ironOreMined
    of bkDiamondOre: inc sim.diamondsMined
    else: discard
    sim.emitEvent(Mine, what = $outcome.minedBlock, x = outcome.minedX,
      y = outcome.minedY, z = outcome.minedZ, amount = 1)
  if outcome.placed:
    inc sim.blocksPlaced
    sim.noteMutation(outcome.placedX, outcome.placedY, outcome.placedZ,
      outcome.placedOver, outcome.placedBlock)
    if outcome.bridged:
      inc sim.bridgesPlaced
      sim.emitEvent(Bridge, x = outcome.placedX, y = outcome.placedY,
        z = outcome.placedZ)
    sim.emitEvent(Place, what = $outcome.placedBlock, x = outcome.placedX,
      y = outcome.placedY, z = outcome.placedZ)
  if outcome.crafted:
    inc sim.itemsCrafted
    sim.emitEvent(Craft, what = $primitive, amount = outcome.craftedCount)
  if outcome.smelted:
    inc sim.ironSmelted
    inc sim.itemsCrafted
    sim.emitEvent(Smelt, amount = 1)
  if outcome.shaftSet:
    inc sim.shaftsDug
    sim.noteShaft(outcome.shaftX, outcome.shaftY, outcome.shaftZ)
  if outcome.descended:
    let first = sim.cog.z > sim.deepestLevel
    if first:
      sim.deepestLevel = sim.cog.z
    sim.emitEvent(Descend, what = levelShortLabel(sim.cog.z),
      x = sim.cog.x, y = sim.cog.y, z = sim.cog.z,
      amount = (if first: 1 else: 0))
  if outcome.ascended:
    sim.emitEvent(Ascend, what = levelShortLabel(sim.cog.z),
      x = sim.cog.x, y = sim.cog.y, z = sim.cog.z)
  if outcome.blocked:
    sim.lastPlan.blocked.add(($primitive, $outcome.why))
    sim.emitEvent(BlockedAct, what = $primitive, why = $outcome.why)
  if outcome.brokeOntoLava:
    sim.emitEvent(LavaFound, x = outcome.lavaX, y = outcome.lavaY,
      z = outcome.lavaZ, amount = 1)

  if sim.cog.z >= 0 and sim.cog.z < sim.ticksPerLevel.len:
    inc sim.ticksPerLevel[sim.cog.z]

  # 4. Milestones.
  sim.evaluateMilestones()

  # 5. Visibility.
  let radius = viewRadius(sim.config, sim.cog.z)
  sim.cellsSeenCount += sim.world.observe(sim.cog.x, sim.cog.y, sim.cog.z,
    radius, sim.gameTicksElapsed())
  if sim.world.hasShaftDown(sim.cog.x, sim.cog.y, sim.cog.z):
    sim.cellsSeenCount += sim.world.observeCell(sim.cog.x, sim.cog.y,
      sim.cog.z + 1, sim.gameTicksElapsed())
  if sim.cog.z > 0 and
      sim.world.hasShaftDown(sim.cog.x, sim.cog.y, sim.cog.z - 1):
    sim.cellsSeenCount += sim.world.observeCell(sim.cog.x, sim.cog.y,
      sim.cog.z - 1, sim.gameTicksElapsed())

  # 6. Death check.
  sim.interruptRequested = false
  if outcome.steppedIntoLava:
    sim.deathCause = DeathCauseLava
    sim.emitEvent(Death, what = "lava")
    sim.finishEpisode(EndRuleDeath, ReasonComplete)
    sim.interruptRequested = true
  # 7. Diamond check: there is nothing left to do and a triumphant early
  #    finish should read as one - and it maximises speedBonus.
  elif sim.ledger.unlocked[msDiamond]:
    sim.finishEpisode(EndRuleDiamond, ReasonComplete)
    sim.interruptRequested = true
  # 8. Interrupt: a newly known adjacent lava ends the turn.
  elif sim.lavaAdjacentNewlyKnown(seenBefore):
    sim.interruptRequested = true
    inc sim.interrupts
    sim.lastPlan.interrupted = "lava_found"
    sim.emitEvent(LavaFound, x = sim.cog.x, y = sim.cog.y, z = sim.cog.z,
      amount = 1)
  # The turn cap is the in-game deadline and the NORMAL way a run ends. The
  # tick cap is an independent guard kept so no arithmetic error can produce an
  # unbounded loop; the two coincide when no turn was ever cut short, and this
  # tick is the last tick of the last turn exactly when `turnsPlayed` is one
  # short of `maxTurns`.
  if sim.phase == Playing and sim.gameTicksElapsed() >= sim.config.maxTicks:
    let rule =
      if sim.turnsPlayed >= sim.config.maxTurns - 1: EndRuleTurnCap
      else: EndRuleTickCap
    sim.finishEpisode(rule, ReasonComplete)
    sim.interruptRequested = true

proc noteTurnEnd*(sim: var SimServer) =
  ## The turn cap is the in-game deadline and the normal way a run ends.
  inc sim.turnsPlayed
  if sim.phase == Playing and sim.turnsPlayed >= sim.config.maxTurns:
    sim.finishEpisode(EndRuleTurnCap, ReasonComplete)

proc pushFeedDirective*(sim: var SimServer, record: string) =
  sim.feedDirectives.add(record)
  if sim.feedDirectives.len > 64:
    sim.feedDirectives.delete(0)

proc lobbyJoinTimedOut*(sim: SimServer): bool =
  sim.phase == Lobby and sim.players.len < sim.config.numAgents and
    sim.lobbyTicks >= sim.config.lobbyJoinTimeoutTicks

proc lobbyStartSecondsRemaining*(sim: SimServer): int =
  if sim.phase != Lobby:
    return 0
  max(0, (sim.config.startWaitTicks - sim.lobbyTicks + TargetFps - 1) div
    TargetFps)

proc eventKey*(kind: SimEventKind): string =
  case kind
  of TurnStart: "turn"
  of Directive: "directive"
  of Fallback: "fallback"
  of PrimitiveRun: "primitive"
  of Mine: "mine"
  of Craft: "craft"
  of Smelt: "smelt"
  of Place: "place"
  of Descend: "descend"
  of Ascend: "ascend"
  of LavaFound: "lava"
  of Bridge: "bridge"
  of BlockedAct: "blocked"
  of MilestoneHit: "milestone"
  of Death: "death"

proc endRuleText*(sim: SimServer): string =
  if sim.endRule.len > 0: sim.endRule else: EndRuleTurnCap

proc reasonText*(sim: SimServer): string =
  if sim.endReason.len > 0: sim.endReason else: ReasonComplete

proc variantName*(sim: SimServer): string =
  sim.config.variantText()

proc describeCog*(sim: SimServer): string =
  seatAlias(0) & " " & levelShortLabel(sim.cog.z) & " facing " &
    ($sim.cog.facing).toUpperAscii()
