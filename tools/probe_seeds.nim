## Probes seeds for a certification fixture that exercises every path the
## CI smoke replay has to carry. Not shipped in the image.
import minecraft/sim, minecraft/driver, minecraft/baselines
proc play(seed: int): tuple[rungs, z, ticks, lava, blocked, digs, ores, crafts: int] =
  var config = defaultGameConfig()
  config.seed = seed
  var sim = initSimServer(config)
  sim.collectEvents = true
  sim.startGame()
  var state = initBaselineState()
  var queue: seq[Primitive] = @[]
  var turnTicks = sim.config.turnTicks
  while sim.phase == Playing:
    if turnTicks >= sim.config.turnTicks:
      let plan = baselinePlan(sim, blMiner, DefaultBaselineParams, state)
      queue = expandPlan(sim, plan).queue
      turnTicks = 0
      sim.noteTurnEnd()
      if sim.phase != Playing: break
    var p = pNoop
    if queue.len > 0:
      p = queue[0]; queue.delete(0)
    sim.step(p)
    inc turnTicks
    for e in sim.events:
      case e.kind
      of LavaFound: inc result.lava
      of BlockedAct: inc result.blocked
      of Mine:
        if e.what in ["coal ore", "iron ore", "diamond ore"]: inc result.ores
      of Craft: inc result.crafts
      of Descend: inc result.digs
      else: discard
    sim.events.setLen(0)
    if sim.interruptRequested:
      queue.setLen(0); turnTicks = sim.config.turnTicks
  (sim.ledger.milestonesReached(), sim.deepestLevel, sim.gameTicksElapsed(),
   result.lava, result.blocked, result.digs, result.ores, result.crafts)
for seed in 1 .. 80:
  let r = play(seed)
  if r.rungs >= 7 and r.z >= 2 and r.ticks >= 400 and r.blocked >= 1 and
      r.digs >= 2 and r.ores >= 1 and r.crafts >= 1:
    echo "seed ", seed, " rungs=", r.rungs, " z=", r.z, " ticks=", r.ticks,
      " lava=", r.lava, " blocked=", r.blocked, " digs=", r.digs,
      " ores=", r.ores, " crafts=", r.crafts
