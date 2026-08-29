## The broadcast event vocabulary is a CLOSED ENUM.
##
## Design note §Tests item 47: the set of kinds `stepEvents` can emit equals
## exactly the sixteen listed in the note, and every kind the appended game
## block handles is in that set.

import std/[algorithm, json, sequtils, strutils]

import minecraft/sim
import minecraft/driver
import minecraft/baselines
import minecraft/broadcast
import minecraft/events

block theClosedEnum:
  var expected = BroadcastEventKinds.toSeq()
  expected.sort()
  doAssert expected.len == 16
  doAssert "milestone" in expected and "newdepth" notin expected,
    "`newdepth` is a `descend` with first: true, not its own emitted kind"
  # The four kinds `stepEvents` cannot emit are decision-layer facts, and the
  # declared step subset is exactly the rest.
  var step = StepEventKinds.toSeq()
  step.sort()
  var difference: seq[string] = @[]
  for kind in expected:
    if kind notin step:
      difference.add(kind)
  doAssert difference == @["fallback", "plan", "say", "turn"],
    "the kinds outside the step subset are " & $difference

  # Play episodes and collect every kind that actually fired. The union must
  # EQUAL the declared step subset: nothing outside it, and nothing in it that
  # cannot be produced.
  var seen: seq[string] = @[]
  for seed in [4, 8, 19]:
    var config = defaultGameConfig()
    config.seed = seed
    var sim = initSimServer(config)
    sim.startGame()
    var tracker = initBroadcastTracker()
    tracker.resync(sim)
    var state = initBaselineState()
    var queue: seq[Primitive] = @[]
    var turnTicks = config.turnTicks
    while sim.phase == Playing:
      if turnTicks >= config.turnTicks:
        queue = expandPlan(sim,
          baselinePlan(sim, blMiner, DefaultBaselineParams, state)).queue
        turnTicks = 0
        sim.noteTurnEnd()
        if sim.phase != Playing:
          break
      var primitive = pNoop
      if queue.len > 0:
        primitive = queue[0]
        queue.delete(0)
      sim.step(primitive)
      inc turnTicks
      let events = newJArray()
      sim.stepEvents(tracker, events)
      for event in events:
        let kind = event["k"].getStr()
        if kind notin seen:
          seen.add(kind)
      if sim.interruptRequested:
        queue.setLen(0)
        turnTicks = config.turnTicks
    # The turn cap ends the episode at a TURN boundary, before the next tick,
    # so the `end` transition is only visible to a diff taken after the loop.
    let tail = newJArray()
    sim.stepEvents(tracker, tail)
    for event in tail:
      let kind = event["k"].getStr()
      if kind notin seen:
        seen.add(kind)
  # `ascend` and the whole crafting chain need a hand-driven cog: the miner
  # never climbs back up a shaft, and a bridge needs lava in front of it.
  block handDriven:
    var config = defaultGameConfig()
    config.seed = 31
    var sim = initSimServer(config)
    sim.startGame()
    var tracker = initBroadcastTracker()
    tracker.resync(sim)
    proc drive(sim: var SimServer, tracker: var BroadcastTracker,
        primitive: Primitive, seen: var seq[string]) =
      sim.step(primitive)
      let events = newJArray()
      sim.stepEvents(tracker, events)
      for event in events:
        let kind = event["k"].getStr()
        if kind notin seen:
          seen.add(kind)
    # ascend: stand on a level with a shaft above and climb it
    sim.cog.z = 1
    sim.world.setShaftDown(sim.cog.x, sim.cog.y, 0, true)
    tracker.resync(sim)                  ## the diff is against z = 1, not 0
    sim.drive(tracker, pClimbUp, seen)
    # bridge: cobblestone into the lava straight ahead
    sim.cog.z = 0
    sim.cog.facing = fcEast
    sim.cog.inventory[itCobblestone] = 8
    sim.world.setBlock(sim.cog.x + 1, sim.cog.y, 0, bkLava)
    sim.drive(tracker, pPlaceBlock, seen)
    # smelt: a furnace, raw iron and coal
    sim.cog.inventory[itRawIron] = 2
    sim.cog.inventory[itCoal] = 2
    sim.world.setBlock(sim.cog.x + 1, sim.cog.y, 0, bkFurnace)
    sim.drive(tracker, pSmeltIron, seen)
    # craft: planks from a log
    sim.cog.inventory[itLog] = 2
    sim.drive(tracker, pCraftPlanks, seen)
    # blocked: mine bedrock
    sim.world.setBlock(sim.cog.x + 1, sim.cog.y, 0, bkBedrock)
    sim.drive(tracker, pMine, seen)
    # lava: walk into range of a lava cell the cog has never seen, so the
    # interrupt fires (a lava cell that is already known never re-fires)
    var walker = initSimServer(config)
    walker.startGame()
    for y in 1 ..< walker.world.levelSize - 1:
      for x in 1 ..< walker.world.levelSize - 1:
        walker.world.setBlock(x, y, 0, bkGrass)
    var walkTracker = initBroadcastTracker()
    walkTracker.resync(walker)
    walker.drive(walkTracker, pNoop, seen)
    walker.world.setBlock(16, 26, 0, bkLava)
    doAssert not walker.world.isSeen(16, 26, 0)
    walker.cog.x = 16
    walker.cog.y = 25
    walkTracker.resync(walker)
    walker.drive(walkTracker, pNoop, seen)
    doAssert walker.interrupts > 0, "the interrupt did not fire"
    # death: step into lava
    sim.world.setBlock(sim.cog.x + 1, sim.cog.y, 0, bkLava)
    sim.drive(tracker, pMoveEast, seen)
  for kind in seen:
    doAssert kind in StepEventKinds,
      "stepEvents emitted an undeclared kind: " & kind
  seen.sort()
  doAssert seen == step,
    "the kinds stepEvents can emit are " & $seen & ", declared " & $step
  echo "ok: stepEvents emits exactly its declared ", seen.len, " kinds"

block gameBlockKindsAreDeclared:
  ## Every `case 'x':` the appended game block handles is a declared kind,
  ## and the five BEAT kinds it draws are exactly the design note's five.
  let page = readFile("client/replay_broadcast.html")
  let banner = "MINECRAFT additions to the inherited coworld-ctf chrome"
  let blockText = page[page.find(banner) .. ^1]
  var handled: seq[string] = @[]
  var index = 0
  while true:
    index = blockText.find("case '", index)
    if index < 0:
      break
    index += "case '".len
    let stop = blockText.find('\'', index)
    if stop < 0:
      break
    handled.add(blockText[index ..< stop])
    index = stop
  handled = handled.deduplicate()
  for kind in handled:
    doAssert kind in BroadcastEventKinds,
      "the game block handles an undeclared event kind: " & kind
  var beats: seq[string] = @[]
  index = 0
  while true:
    index = blockText.find("mcBeat(s, ", index)
    if index < 0:
      break
    index += "mcBeat(s, ".len
    let comma = blockText.find(", '", index)
    if comma < 0 or comma - index > 120:
      # The declaration `function mcBeat(s, tick, kind, label)` has no literal
      # kind; skip it rather than reading the next quoted token in the file.
      continue
    let start = comma + 3
    let stop = blockText.find('\'', start)
    beats.add(blockText[start ..< stop])
    index = max(index, stop)
  beats = beats.deduplicate()
  beats.sort()
  doAssert beats == @["death", "end", "fallback", "milestone", "newdepth"],
    "the game block draws beats for " & $beats
  echo "ok: the game block handles ", handled.len,
    " declared kinds and draws exactly five beat kinds"

block tierTwoStream:
  ## The tier-2 JSON-lines stream keeps the mandatory trailing summary row.
  var config = defaultGameConfig()
  config.seed = 42
  var sim = initSimServer(config)
  sim.collectEvents = true
  sim.startGame()
  for i in 0 ..< 40:
    sim.step(pNoop)
  let lines = sim.events.eventsJsonl(sim.tickCount).splitLines()
  var rows = 0
  for line in lines:
    if line.strip().len > 0:
      inc rows
  doAssert rows >= 1
  let summary = parseJson(lines[rows - 1])
  doAssert summary["type"].getStr == "summary"
  doAssert summary["gameVersion"].getStr == GameVersion
  doAssert summary.hasKey("ticks") and summary.hasKey("events")
  var kinds: seq[string] = @[]
  for kind in SimEventKind:
    doAssert kind.eventKey().len > 0
    kinds.add(kind.eventKey())
  doAssert kinds.deduplicate().len == kinds.len, "duplicate tier-2 event key"
  echo "ok: the tier-2 stream keeps its summary row and ", kinds.len,
    " distinct kinds"

echo "test_minecraft_events: PASS"
