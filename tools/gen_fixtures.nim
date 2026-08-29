## Regenerates the committed replay fixtures under `tests/fixtures/`.
##
## The fixtures are what `tools/wasm_replay_smoke.cjs` runs the EXACT emitted
## wasm module against, and what `tests/test_minecraft_replay.nim`'s
## GameVersion sweep checks. Re-run this in the same commit as any
## `GameVersion` bump:
##
##   nim r -d:release --path:src tools/gen_fixtures.nim
##
import std/[os, json]
import minecraft/sim, minecraft/directives, minecraft/driver,
  minecraft/baselines, minecraft/decide, minecraft/replays
proc gen(seed: int, path: string) =
  var config = defaultGameConfig()
  config.seed = seed
  config.slots = @[PlayerSlotConfig(name: "daveey", token: "token-0")]
  var sim = initSimServer(config)
  var writer = openReplayWriter(path, config.configJson())
  var engine = initDecisionEngine(sim)
  engine.seats[0].registered = true
  engine.seats[0].baseline = blMiner
  engine.seats[0].label = "miner"
  sim.seatNames[0] = "daveey"
  writer.writeJoin(tickTime(0), 0, "daveey", 0, "token-0")
  writer.writeChat(tickTime(0), 0, registerRecord(0, seatAlias(0), "miner", "scripted", "miner"))
  block:
    let r = startRecord(); writer.writeChat(tickTime(sim.tickCount), 0, r); sim.applyControlRecord(r)
  var queue: seq[Primitive] = @[]
  var turnTicks = config.turnTicks
  var turnIndex = 0
  while sim.phase == Playing:
    if turnTicks >= config.turnTicks:
      let view = sim.observationJson(turnIndex, includeNotes = false)
      sim.lastPlan = LastPlan(interrupted: "")
      for rec in engine.turn(sim, turnIndex, 0):
        writer.writeChat(tickTime(sim.tickCount), 0, rec)
      var plan = engine.plans[0]
      queue = expandPlan(sim, plan).queue
      writer.writeChat(tickTime(sim.tickCount), 0,
        directiveRecord(turnIndex, sim.gameTicksElapsed(), 0, seatAlias(0), plan,
          primitiveNames(queue), false, 0, 0, @[], "", view))
      turnTicks = 0
    var p = pNoop
    if queue.len > 0: p = queue[0]; queue.delete(0)
    writer.writePrimitive(sim.tickCount, p)
    sim.step(p)
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
    inc turnTicks
    if sim.interruptRequested or turnTicks >= config.turnTicks or sim.phase != Playing:
      queue.setLen(0); inc turnIndex
      let r = turnEndRecord(); writer.writeChat(tickTime(sim.tickCount), 0, r)
      sim.applyControlRecord(r)
      turnTicks = config.turnTicks
  writer.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
  writer.closeReplayWriter()
  echo path, " rungs=", sim.ledger.milestonesReached(), " ticks=", sim.gameTicksElapsed(), " bytes=", getFileSize(path)
gen(42, "tests/fixtures/cert_seed_42.replay")
gen(8, "tests/fixtures/diamond_seed_8.replay")
