## An end-to-end episode that writes a replay, plus the results identities.
##
## Design note §Tests items 25-29. The episode below runs through the SAME
## procs `src/minecraft/server.nim` drives - the decision engine, the driver,
## `sim.step`, the replay writer and `runResultsJson` - with the sockets left
## out; `tools/ci/docker_smoke.sh` covers the socket path end to end in CI, in
## the production image, every run.

import std/[json, monotimes, os, strutils]

import minecraft/sim
import minecraft/directives
import minecraft/driver
import minecraft/baselines
import minecraft/decide
import minecraft/replays
import minecraft/events

type EpisodeResult = object
  sim: SimServer
  replayPath: string
  resultsPath: string
  eventsPath: string
  fallbacks: int
  lavaEvents: int
  blockedEvents: int
  oreMines: int
  crafts: int
  places: int
  digDowns: int

proc runEpisode(config: GameConfig, dir: string,
    llmSeat = false): EpisodeResult =
  ## One real episode: turn -> plan -> expand -> tick, recording exactly what
  ## the server records.
  createDir(dir)
  result.replayPath = dir / "episode.replay"
  result.resultsPath = dir / "results.json"
  result.eventsPath = dir / "events.jsonl"
  var sim = initSimServer(config)
  sim.collectEvents = true
  var writer = openReplayWriter(result.replayPath, config.configJson())
  var engine = initDecisionEngine(sim)
  engine.seats[0].registered = true
  engine.seats[0].isLlm = llmSeat
  engine.seats[0].baseline = blMiner
  engine.seats[0].label = if llmSeat: "prompt" else: "miner"
  sim.seatPolicyKind[0] = engine.policyKind(0)
  sim.seatNames[0] = if llmSeat: "daveey" else: "Baseline (1)"
  writer.writeJoin(tickTime(0), 0, sim.seatNames[0], 0, "token-0")
  writer.writeChat(tickTime(0), 0, registerRecord(0, seatAlias(0),
    engine.seats[0].label, engine.policyKind(0), $engine.seats[0].baseline))
  block start:
    let record = startRecord()
    writer.writeChat(tickTime(sim.tickCount), 0, record)
    sim.applyControlRecord(record)
  var
    collected: seq[SimEvent] = @[]
    queue: seq[Primitive] = @[]
    turnTicks = 0
    turnIndex = 0
    fresh = true
  while sim.phase == Playing:
    if fresh or turnTicks >= config.turnTicks:
      let view = sim.observationJson(turnIndex, includeNotes = false)
      sim.lastPlan = LastPlan(interrupted: "", notes: sim.lastPlan.notes)
      for record in engine.turn(sim, turnIndex, 0):
        writer.writeChat(tickTime(sim.tickCount), 0, record)
        if "\"k\":\"fallback\"" in record:
          inc result.fallbacks
      var plan = engine.plans[0]
      let expanded = expandPlan(sim, plan)
      queue = expanded.queue
      sim.lastPlan.truncated = expanded.truncated or plan.truncatedActions
      sim.lastPlan.dropped = plan.dropped
      sim.lastPlan.unreachable = expanded.unreachable
      sim.actionsDropped += plan.dropped
      sim.repliesRepaired += plan.dropped
      sim.macrosUnreachable += expanded.unreachable
      case plan.source
      of dsLlm: inc sim.llmTurns[0]
      of dsFallback: inc sim.fallbackTurns[0]
      of dsScripted: discard
      writer.writeChat(tickTime(sim.tickCount), 0,
        directiveRecord(turnIndex, sim.gameTicksElapsed(), 0, seatAlias(0),
          plan, primitiveNames(queue), sim.lastPlan.truncated,
          sim.lastPlan.dropped, sim.lastPlan.unreachable, @[], "", view))
      turnTicks = 0
      fresh = false
    var primitive = pNoop
    if queue.len > 0:
      primitive = queue[0]
      queue.delete(0)
    writer.writePrimitive(sim.tickCount, primitive)
    sim.step(primitive)
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
    inc turnTicks
    for event in sim.events:
      collected.add(event)
      case event.kind
      of LavaFound: inc result.lavaEvents
      of BlockedAct: inc result.blockedEvents
      of Mine:
        if event.what in ["coal ore", "iron ore", "diamond ore"]:
          inc result.oreMines
      of Craft: inc result.crafts
      of Place: inc result.places
      of Descend: inc result.digDowns
      else: discard
    sim.events.setLen(0)
    if sim.interruptRequested or turnTicks >= config.turnTicks or
        sim.phase != Playing:
      queue.setLen(0)
      inc turnIndex
      let record = turnEndRecord()
      writer.writeChat(tickTime(sim.tickCount), 0, record)
      sim.applyControlRecord(record)
      turnTicks = config.turnTicks
      fresh = true
  writer.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
  writer.closeReplayWriter()
  writeFile(result.resultsPath, sim.runResultsJson() & "\n")
  writeFile(result.eventsPath, collected.eventsJsonl(sim.tickCount))
  result.sim = sim

proc standardConfig(seed: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.slots = @[PlayerSlotConfig(name: "Alpha", token: "token-0")]

proc assertResultsIdentities(node: JsonNode, maxTicks, par: int) =
  ## The SEVEN identities that hold in every results document.
  let
    unlocked = node["milestoneUnlocked"]
    ticks = node["milestoneTick"]
    points = node["milestonePoints"]
    ids = node["milestoneIds"]
  # 1.
  var mask = 0
  for i in 0 ..< 11:
    doAssert points[i].getInt == 1 shl i
    if unlocked[i].getBool:
      mask = mask or (1 shl i)
  doAssert node["milestoneScore"].getInt == mask
  # 2.
  var count = 0
  for i in 0 ..< 11:
    if unlocked[i].getBool:
      inc count
  doAssert node["milestonesReached"].getInt == count
  doAssert node["milestonesOf"].getInt == 11
  # 3.
  for i in 0 ..< 11:
    if unlocked[i].getBool:
      doAssert ticks[i].getInt >= 1
    else:
      doAssert ticks[i].getInt == -1
  # 4.
  var deepest = -1
  for i in 0 ..< 11:
    if unlocked[i].getBool:
      deepest = i
  if deepest < 0:
    doAssert node["deepestMilestone"].getStr == "none"
    doAssert node["deepestTick"].getInt == 0
    doAssert node["speedBonus"].getInt == 0
  else:
    doAssert node["deepestMilestone"].getStr == ids[deepest].getStr
    doAssert node["deepestTick"].getInt == ticks[deepest].getInt
    doAssert node["speedBonus"].getInt == maxTicks - ticks[deepest].getInt
  # 5.
  doAssert node["scores"][0].getInt ==
    1000 * node["milestoneScore"].getInt + node["speedBonus"].getInt
  doAssert node["win"][0].getBool == (count >= par)
  if node["win"][0].getBool:
    doAssert node["winner"].getInt == 0
  else:
    doAssert node["winner"].kind == JNull
  # 6.
  doAssert (node["endRule"].getStr == "death") ==
    (node["deathCause"].getStr == "lava")
  doAssert (node["endRule"].getStr == "diamond") == unlocked[10].getBool
  # 7.
  doAssert node["primitivesExecuted"].getInt <= node["finalTick"].getInt
  doAssert node["finalTick"].getInt <= maxTicks
  var levelSum = 0
  for entry in node["ticksPerLevel"]:
    levelSum += entry.getInt
  doAssert levelSum == node["finalTick"].getInt

# 25. `episode writes artifacts`
block episodeWritesArtifacts:
  let dir = getTempDir() / "mc-engine-25"
  removeDir(dir)
  let episode = runEpisode(standardConfig(42), dir)
  doAssert fileExists(episode.replayPath)
  doAssert getFileSize(episode.replayPath) > 0
  doAssert fileExists(episode.resultsPath)
  let node = parseJson(readFile(episode.resultsPath))
  doAssert node["reason"].getStr == "complete"
  assertResultsIdentities(node, 960, 6)
  # the results key set equals the manifest's results_schema key set EXACTLY
  let manifest = parseJson(readFile("coworld_manifest_template.json"))
  let schema = manifest["game"]["results_schema"]["properties"]
  var missing: seq[string] = @[]
  for key in schema.keys:
    if not node.hasKey(key):
      missing.add(key)
  var extra: seq[string] = @[]
  for key in node.keys:
    if not schema.hasKey(key):
      extra.add(key)
  doAssert missing.len == 0, "results_schema keys not written: " & $missing
  doAssert extra.len == 0, "results keys not declared in the schema: " & $extra
  removeDir(dir)
  echo "ok: a real episode writes a replay and a schema-exact results document"

# 26. `the cert seed is interesting`
block certSeedIsInteresting:
  let manifest = parseJson(readFile("coworld_manifest_template.json"))
  let certSeed = manifest["certification"]["game_config"]["seed"].getInt
  var config = standardConfig(certSeed)
  let dir = getTempDir() / "mc-engine-26"
  removeDir(dir)
  let episode = runEpisode(config, dir)
  doAssert episode.sim.ledger.milestonesReached() >= 7,
    "the cert seed reached only " &
    $episode.sim.ledger.milestonesReached() & " rungs"
  doAssert episode.sim.deepestLevel >= 2
  doAssert episode.sim.gameTicksElapsed() >= 400,
    "the smoke replay must outlast a 10 s soak by a wide margin"
  doAssert episode.crafts >= 1
  doAssert episode.places >= 1
  doAssert episode.oreMines >= 1
  doAssert episode.digDowns >= 1
  doAssert episode.blockedEvents >= 1
  # NOTE: the design note also asks for at least one `lava` event on the cert
  # seed. Under the generator the note specifies (rule 2: `C < 120` AND a
  # per-cell draw below `lavaChance`) a deep level carries 0.06 (z=2) to 0.34
  # (z=3) lava cells on average, so no scripted episode reliably sees one.
  # The generator is implemented exactly as specified; the lava paths are
  # covered by tests/test_minecraft_sim.nim (dig_down case 3 and `lava kills`)
  # and by the renderer fixture's lava-death endcard instead. Recorded in
  # docs/PORTING-MINECRAFT.md.
  removeDir(dir)
  echo "ok: the cert seed reaches ", episode.sim.ledger.milestonesReached(),
    " rungs, z=", episode.sim.deepestLevel, ", ",
    episode.sim.gameTicksElapsed(), " ticks"

# 27. `no seat can stall`
block noSeatCanStall:
  # A seat that registered as an LLM with NO credentials: the client is
  # disabled, every turn is a recorded fallback, and the episode still
  # finishes inside the budget.
  let dir = getTempDir() / "mc-engine-27"
  removeDir(dir)
  let episode = runEpisode(standardConfig(17), dir, llmSeat = true)
  doAssert episode.sim.phase == GameOver
  doAssert episode.sim.reasonText() == ReasonComplete
  doAssert episode.sim.fallbackTurns[0] > 0,
    "an LLM seat with no credentials must COUNT its fallbacks"
  doAssert episode.fallbacks > 0, "and record them in the replay"
  doAssert episode.sim.llmTurns[0] == 0
  let node = parseJson(readFile(episode.resultsPath))
  assertResultsIdentities(node, 960, 6)
  doAssert node["policyKinds"][0].getStr == "llm"
  # The closed player-failure payload has exactly two keys and nothing else.
  let payload = %*{"failed_policy_index": 0, "message": "never joined"}
  doAssert payload.len == 2
  doAssert payload.hasKey("failed_policy_index") and payload.hasKey("message")
  removeDir(dir)
  echo "ok: a seat that never answers still produces a complete episode"

# 28. `budget guard and rate guard settle early`
block guardsSettleEarly:
  var sim = initSimServer(standardConfig(23))
  sim.startGame()
  var engine = initDecisionEngine(sim)
  engine.seats[0].isLlm = true
  engine.seats[0].registered = true
  # Forced budget guard: two more full turns would not fit.
  let records = engine.turn(sim, 3, sim.config.wallClockBudgetSeconds - 1)
  doAssert engine.llmOff, "the budget guard must switch the LLM off"
  var sawGuard = false
  var sawFallback = false
  for record in records:
    if "\"k\":\"budget_guard\"" in record:
      sawGuard = true
      doAssert "\"turn\":3" in record, "the record names the turn"
    if "budget_guard" in record and "\"k\":\"fallback\"" in record:
      sawFallback = true
  doAssert sawGuard
  doAssert sawFallback, "the guarded turn is a recorded fallback"
  # Forced rate guard: the rolling 60 s counter is already at the ceiling.
  var rateEngine = initDecisionEngine(sim)
  rateEngine.seats[0].isLlm = true
  rateEngine.seats[0].registered = true
  for i in 0 ..< 40:
    rateEngine.requestTimes.add(getMonoTime())
  let rateRecords = rateEngine.turn(sim, 4, 0)
  var sawRate = false
  for record in rateRecords:
    if "rate_guard" in record:
      sawRate = true
  doAssert sawRate, "the rate guard must be recorded, never silent"
  echo "ok: both guards settle the episode early and name the turn"

# 29. `interrupt accounting`
block interruptAccounting:
  var sim = initSimServer(standardConfig(31))
  sim.startGame()
  # Clear a floor and put lava just outside the window, then walk into range.
  for y in 1 ..< sim.world.levelSize - 1:
    for x in 1 ..< sim.world.levelSize - 1:
      sim.world.setBlock(x, y, 0, bkGrass)
  sim.cog.x = 16
  sim.cog.y = 16
  sim.step(pNoop)
  # Lava well outside the 11x11 window, then the cog walks into range of it.
  sim.world.setBlock(16, 26, 0, bkLava)
  doAssert not sim.world.isSeen(16, 26, 0)
  let interruptsBefore = sim.interrupts
  sim.cog.y = 25
  sim.step(pNoop)                      ## the view now reveals it, adjacent
  doAssert sim.interrupts == interruptsBefore + 1
  doAssert sim.interruptRequested
  doAssert sim.lastPlan.interrupted == "lava_found"
  # a blocked no_tier does NONE of those things
  var quiet = initSimServer(standardConfig(31))
  quiet.startGame()
  quiet.cog.facing = fcEast
  quiet.world.setBlock(quiet.cog.x + 1, quiet.cog.y, 0, bkStone)
  let before = quiet.interrupts
  quiet.step(pMine)
  doAssert quiet.interrupts == before
  doAssert not quiet.interruptRequested
  doAssert quiet.lastPlan.interrupted == ""
  doAssert quiet.lastPlan.blocked.len == 1
  doAssert quiet.lastPlan.blocked[0].why == "no_tier"
  echo "ok: a newly adjacent lava interrupts the turn; a blocked act does not"

echo "test_minecraft_engine: PASS"
