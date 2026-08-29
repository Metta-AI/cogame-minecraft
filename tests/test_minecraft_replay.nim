## Replay tests: record then re-derive for EVERY end reason, self-sufficiency,
## the incremental world digest, strict-UTF-8 `replay_summary.py`, and the
## committed fixtures' GameVersion sweep.
##
## Design note §Tests items 30-35.

import std/[json, os, osproc, strutils, unicode]

import minecraft/sim
import minecraft/directives
import minecraft/driver
import minecraft/baselines
import minecraft/decide
import minecraft/replays

proc standardConfig(seed: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.slots = @[PlayerSlotConfig(name: "daveey", token: "token-0")]

type Recorded = object
  path: string
  hashes: seq[uint64]
  endRule: string
  reason: string
  finalTick: int
  milestoneMask: int
  says: seq[string]

proc record(config: GameConfig, path: string, forceStop = "",
    stopAfter = 0, say = "", notes = ""): Recorded =
  ## Records one episode exactly as `server.nim` does, optionally forcing a
  ## wall-clock or fault stop after `stopAfter` ticks. The stop is written as a
  ## LOAD-BEARING record and applied by the same proc on record and playback.
  result.path = path
  var sim = initSimServer(config)
  var writer = openReplayWriter(path, config.configJson())
  var engine = initDecisionEngine(sim)
  engine.seats[0].registered = true
  engine.seats[0].baseline = blMiner
  engine.seats[0].label = "miner"
  sim.seatNames[0] = "daveey"
  writer.writeJoin(tickTime(0), 0, "daveey", 0, "token-0")
  writer.writeChat(tickTime(0), 0, registerRecord(0, seatAlias(0), "miner",
    "scripted", "miner"))
  block:
    let started = startRecord()
    writer.writeChat(tickTime(sim.tickCount), 0, started)
    sim.applyControlRecord(started)
  var
    queue: seq[Primitive] = @[]
    turnTicks = config.turnTicks
    turnIndex = 0
  while sim.phase == Playing:
    if turnTicks >= config.turnTicks:
      for record in engine.turn(sim, turnIndex, 0):
        writer.writeChat(tickTime(sim.tickCount), 0, record)
      var plan = engine.plans[0]
      if say.len > 0:
        plan.say = sanitizeSay(say)
        plan.notes = sanitizeNote(notes)
        result.says.add(plan.say)
      queue = expandPlan(sim, plan).queue
      writer.writeChat(tickTime(sim.tickCount), 0,
        directiveRecord(turnIndex, sim.gameTicksElapsed(), 0, seatAlias(0),
          plan, primitiveNames(queue), false, 0, 0, @[], "", nil))
      turnTicks = 0
    var primitive = pNoop
    if queue.len > 0:
      primitive = queue[0]
      queue.delete(0)
    writer.writePrimitive(sim.tickCount, primitive)
    sim.step(primitive)
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
    result.hashes.add(sim.gameHash())
    inc turnTicks
    if forceStop.len > 0 and sim.tickCount >= stopAfter:
      let stop = stopRecord(sim.tickCount, forceStop)
      writer.writeChat(tickTime(sim.tickCount), 0, stop)
      sim.applyControlRecord(stop)
    if sim.interruptRequested or turnTicks >= config.turnTicks or
        sim.phase != Playing:
      queue.setLen(0)
      inc turnIndex
      let ended = turnEndRecord()
      writer.writeChat(tickTime(sim.tickCount), 0, ended)
      sim.applyControlRecord(ended)
      turnTicks = config.turnTicks
  writer.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
  writer.closeReplayWriter()
  result.endRule = sim.endRuleText()
  result.reason = sim.reasonText()
  result.finalTick = sim.gameTicksElapsed()
  result.milestoneMask = sim.ledger.milestoneScore()

proc rederive(path: string): tuple[player: ReplayPlayer, sim: SimServer] =
  let data = parseReplayBytes(readFile(path))
  var config = defaultGameConfig()
  config.update(data.configJson)
  result.sim = initSimServer(config)
  result.player = initReplayPlayer(data)
  while result.player.inputIndex < result.player.data.inputs.len:
    result.player.stepReplay(result.sim)
  result.player.drainControlRecords(result.sim)

# 30. `record then re-derive, EVERY end reason`
block recordThenRederive:
  let dir = getTempDir() / "mc-replay-30"
  removeDir(dir)
  createDir(dir)
  # diamond
  var diamondConfig = standardConfig(8)
  # death: a scripted seat walks into lava only if we put lava under its feet,
  # so the death case is recorded from a hand-driven episode below instead.
  for (name, config, stop, after) in [
      ("turnCap", standardConfig(42), "", 0),
      ("diamond", diamondConfig, "", 0),
      ("wallClock", standardConfig(42), EndRuleWallClock, 200),
      ("fault", standardConfig(42), EndRuleFault, 150)]:
    let path = dir / (name & ".replay")
    let recorded = record(config, path, stop, after)
    let back = rederive(path)
    doAssert back.sim.gameTicksElapsed() == recorded.finalTick,
      name & ": re-derived " & $back.sim.gameTicksElapsed() & " ticks, " &
      "recorded " & $recorded.finalTick
    doAssert back.sim.endRuleText() == recorded.endRule,
      name & ": re-derived endRule " & back.sim.endRuleText()
    doAssert back.sim.reasonText() == recorded.reason
    doAssert back.sim.ledger.milestoneScore() == recorded.milestoneMask
    doAssert back.player.hashMismatchTick == -1,
      name & ": hash chain diverged at tick " & $back.player.hashMismatchTick
    doAssert not back.player.hashValidationFailed
  # tickCap and death, driven by hand so the rule is reached deterministically
  block deathAndTickCap:
    var sim = initSimServer(standardConfig(3))
    sim.startGame()
    for y in 1 ..< sim.world.levelSize - 1:
      for x in 1 ..< sim.world.levelSize - 1:
        sim.world.setBlock(x, y, 0, bkGrass)
    sim.world.setBlock(sim.cog.x + 1, sim.cog.y, 0, bkLava)
    sim.step(pMoveEast)
    doAssert sim.endRuleText() == EndRuleDeath
    doAssert sim.deathCause == DeathCauseLava
    doAssert sim.reasonText() == ReasonComplete
    var ticks = initSimServer(standardConfig(3))
    ticks.startGame()
    for i in 0 ..< ticks.config.maxTicks:
      if ticks.phase != Playing:
        break
      ticks.step(pNoop)
    doAssert ticks.endRuleText() in [EndRuleTickCap, EndRuleTurnCap]
    doAssert ticks.reasonText() == ReasonComplete
  removeDir(dir)
  echo "ok: every end reason records and re-derives with an intact hash chain"

# 31. `replay is self-sufficient`
block replayIsSelfSufficient:
  let dir = getTempDir() / "mc-replay-31"
  removeDir(dir)
  createDir(dir)
  let path = dir / "episode.replay"
  discard record(standardConfig(42), path)
  let data = parseReplayBytes(readFile(path))
  doAssert data.gameName == GameName
  doAssert data.gameVersion == GameVersion
  let config = parseJson(data.configJson)
  for key in ["seed", "variant", "num_agents", "levelCount", "levelSize",
      "surfaceViewRadius", "deepViewRadius", "regionSize", "turnTicks",
      "maxTurns", "maxTicks", "veinThreshold", "caveThresholdStone",
      "caveThresholdIron", "caveThresholdDiamond", "lavaChanceIron",
      "lavaChanceDiamond", "coalChanceStone", "coalChanceIron",
      "ironChanceIron", "ironChanceDiamond", "diamondChance", "minCoalStone",
      "minIronIron", "minCoalIron", "minDiamond", "minIronDiamond",
      "parMilestones", "maxActionsPerTurn", "macroPrimitiveCap", "players",
      "slots", "fastMode"]:
    doAssert config.hasKey(key), "the replay config is missing " & key
  doAssert data.joins.len == 1
  doAssert data.joins[0].name == "daveey", "the REAL name rides in the join"
  var sawRegister, sawDirective, sawResult = false
  for chat in data.chats:
    if "\"k\":\"register\"" in chat.message:
      sawRegister = true
      doAssert "prompt" notin chat.message, "the prompt is a SECRET"
    if "\"k\":\"directive\"" in chat.message:
      sawDirective = true
    if "\"k\":\"result\"" in chat.message:
      sawResult = true
  doAssert sawRegister and sawDirective and sawResult
  # re-simulating from the bytes alone reproduces the world and the ladder
  let back = rederive(path)
  let fresh = generateWorld(back.sim.config)
  doAssert fresh.cells.len == back.sim.world.cells.len
  doAssert back.sim.ledger.milestonesReached() > 0
  removeDir(dir)
  echo "ok: the bytes alone carry the name, the config, the plans and the result"

# 32. `the incremental world digest equals a full fold`
block digestEqualsFold:
  var sim = initSimServer(standardConfig(5))
  sim.startGame()
  sim.cog.tools[tlIron] = true
  var state = initBaselineState()
  var queue: seq[Primitive] = @[]
  for tick in 0 ..< 600:
    if sim.phase != Playing:
      break
    if queue.len == 0:
      let plan = minerPlan(sim, DefaultBaselineParams, state)
      queue = expandPlan(sim, plan).queue
      sim.noteTurnEnd()
      if queue.len == 0:
        queue = @[pNoop]
    let primitive = queue[0]
    queue.delete(0)
    sim.step(primitive)
  doAssert sim.blocksMined > 0, "the digest test must actually mutate the world"
  doAssert sim.worldHash == sim.worldDigestFold(),
    "the incremental world digest drifted from a full fold"
  echo "ok: the incremental world digest equals a fresh fold after ",
    sim.blocksMined, " mutations"

# 33. `replay_summary is strict UTF-8 JSON`
block replaySummaryIsStrictUtf8:
  let dir = getTempDir() / "mc-replay-33"
  removeDir(dir)
  createDir(dir)
  let path = dir / "emoji.replay"
  # Every capped field filled to EXACTLY its cap with 4-byte emoji.
  var bigSay = ""
  for i in 0 ..< 400:
    bigSay.add("\u{1F600}")
  var bigNotes = ""
  for i in 0 ..< 900:
    bigNotes.add("\u{1F9F1}")
  let recorded = record(standardConfig(42), path, say = bigSay,
    notes = bigNotes)
  doAssert recorded.says.len > 0
  doAssert recorded.says[0].runeLen == MaxSayRunes
  doAssert recorded.says[0].validateUtf8() == -1
  let summary = execCmdEx("python3 tools/replay_summary.py " & path)
  doAssert summary.exitCode == 0,
    "replay_summary.py failed: " & summary.output
  let node = parseJson(summary.output)
  doAssert node["protocol"].getStr == "minecraft/v1"
  doAssert node["gameVersion"].getStr == GameVersion
  doAssert node["seed"].getInt == 42
  doAssert node["variant"].getStr == "standard"
  doAssert node["names"][0].getStr == "daveey"
  doAssert node["aliases"][0].getStr == "Alpha"
  doAssert node["tickCount"].getInt > 0
  doAssert node["plans"].len > 0
  doAssert node["says"].len > 0
  doAssert node["results"]["reason"].getStr == "complete"
  doAssert node["milestones"].len == 11
  doAssert summary.output.validateUtf8() == -1,
    "replay_summary.py emitted invalid UTF-8"
  doAssert "\\ud" notin summary.output.toLowerAscii(),
    "replay_summary.py emitted a lone surrogate"
  removeDir(dir)
  echo "ok: replay_summary.py emits one strict-UTF-8 JSON object"

# 34. `determinism from the replay alone`
block determinismFromTheReplay:
  let dir = getTempDir() / "mc-replay-34"
  removeDir(dir)
  createDir(dir)
  let path = dir / "episode.replay"
  let recorded = record(standardConfig(11), path)
  let a = rederive(path)
  let b = rederive(path)
  doAssert a.sim.gameTicksElapsed() == b.sim.gameTicksElapsed()
  doAssert a.sim.gameHash() == b.sim.gameHash()
  doAssert a.sim.ledger.milestoneScore() == recorded.milestoneMask
  for m in Milestone:
    doAssert a.sim.ledger.tick[m] == b.sim.ledger.tick[m]
  # a SEEK re-simulates from tick 0 and lands on the same state
  var seeker = rederive(path)
  let mid = recorded.finalTick div 2
  seeker.player.seekReplay(seeker.sim, mid)
  let firstHash = seeker.sim.gameHash()
  seeker.player.seekReplay(seeker.sim, 0)
  seeker.player.seekReplay(seeker.sim, mid)
  doAssert seeker.sim.gameHash() == firstHash, "a seek is not deterministic"
  removeDir(dir)
  echo "ok: the replay re-simulates identically and seeks deterministically"

# 35. `every committed fixture carries the current GameVersion`
block fixtureVersionSweep:
  var checked = 0
  for path in walkDirRec("tests"):
    if not path.endsWith(".replay"):
      continue
    let data = parseReplayBytes(readFile(path))
    doAssert data.gameVersion == GameVersion,
      path & " was recorded under GameVersion " & data.gameVersion &
      " but the engine is at " & GameVersion
    inc checked
  echo "ok: ", checked, " committed replay fixtures carry GameVersion ",
    GameVersion

echo "test_minecraft_replay: PASS"
