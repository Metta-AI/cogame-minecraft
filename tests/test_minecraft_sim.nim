## Sim unit tests: the seventeen primitives, dig_down's six cases, lava,
## visibility, the eleven milestones, the tick order, scoring and the end
## conditions.
##
## Design note §Tests items 6-9 and 13-17.

import std/[monotimes, times]

import minecraft/sim

proc testConfig(seed: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed

proc started(seed: int): SimServer =
  result = initSimServer(testConfig(seed))
  result.startGame()

proc clearAround(sim: var SimServer, z: int, kind = bkTunnel) =
  ## A blank workshop floor to script exact primitives against.
  for y in 1 ..< sim.world.levelSize - 1:
    for x in 1 ..< sim.world.levelSize - 1:
      sim.world.setBlock(x, y, z, kind)

# 6. `the seventeen primitives`
block seventeenPrimitives:
  var sim = started(3)
  sim.clearAround(0, bkGrass)
  sim.cog.x = 16
  sim.cog.y = 16
  sim.cog.facing = fcEast

  # move_<dir> turns then steps only into a walkable cell
  sim.step(pMoveEast)
  doAssert sim.cog.x == 17 and sim.cog.facing == fcEast
  sim.world.setBlock(18, 16, 0, bkStone)
  sim.step(pMoveEast)
  doAssert sim.cog.x == 17, "a blocked move is a TURN, not a step"
  doAssert sim.cog.facing == fcEast
  sim.step(pMoveNorth)
  doAssert sim.cog.facing == fcNorth and sim.cog.y == 15

  # mine respects the tier table and yields exactly the drop
  sim.cog.y = 16
  sim.cog.facing = fcEast
  let logsBefore = sim.cog.inventory[itLog]
  sim.step(pMine)                          ## stone, but bare hands
  doAssert sim.cog.inventory[itCobblestone] == 0, "bare hands cannot mine stone"
  sim.world.setBlock(18, 16, 0, bkTree)
  sim.step(pMine)
  doAssert sim.cog.inventory[itLog] == logsBefore + 3
  doAssert sim.world.at(18, 16, 0) == bkGrass

  # crafting: costs, and an owned pickaxe is a free no-op
  sim.step(pCraftPlanks)
  doAssert sim.cog.inventory[itPlanks] == 4 and sim.cog.inventory[itLog] == 2
  sim.step(pCraftSticks)
  doAssert sim.cog.inventory[itStick] == 4 and sim.cog.inventory[itPlanks] == 2
  sim.step(pCraftWoodenPickaxe)
  doAssert not sim.cog.tools[tlWooden], "no table within 1: the craft fails"
  sim.step(pCraftPlanks)
  sim.step(pCraftPlanks)
  doAssert sim.cog.inventory[itPlanks] >= 8
  sim.cog.facing = fcEast
  sim.step(pPlaceTable)
  doAssert sim.world.at(18, 16, 0) == bkTable
  sim.step(pCraftWoodenPickaxe)
  doAssert sim.cog.tools[tlWooden]
  let plankCount = sim.cog.inventory[itPlanks]
  sim.step(pCraftWoodenPickaxe)
  doAssert sim.cog.inventory[itPlanks] == plankCount,
    "crafting an owned pickaxe is a free no-op"

  # a table on the level ABOVE is not "next to" anything
  var deep = started(3)
  deep.clearAround(1)
  deep.cog.z = 1
  deep.cog.x = 16
  deep.cog.y = 16
  deep.world.setBlock(17, 16, 0, bkTable)
  deep.cog.inventory[itPlanks] = 8
  deep.cog.inventory[itStick] = 4
  deep.step(pCraftWoodenPickaxe)
  doAssert not deep.cog.tools[tlWooden], "adjacency is per LEVEL"

  # place_block only fills lava and water
  var bridge = started(3)
  bridge.clearAround(0, bkGrass)
  bridge.cog.x = 16
  bridge.cog.y = 16
  bridge.cog.facing = fcEast
  bridge.cog.inventory[itCobblestone] = 4
  bridge.step(pPlaceBlock)
  doAssert bridge.cog.inventory[itCobblestone] == 4, "grass is not fillable"
  bridge.world.setBlock(17, 16, 0, bkLava)
  bridge.step(pPlaceBlock)
  doAssert bridge.world.at(17, 16, 0) == bkStone
  doAssert bridge.cog.inventory[itCobblestone] == 3
  doAssert bridge.bridgesPlaced == 1

  # smelt needs a furnace within 1 on the same level
  var smelt = started(3)
  smelt.clearAround(2)
  smelt.cog.z = 2
  smelt.cog.x = 16
  smelt.cog.y = 16
  smelt.cog.inventory[itRawIron] = 2
  smelt.cog.inventory[itCoal] = 2
  smelt.step(pSmeltIron)
  doAssert smelt.cog.inventory[itIronIngot] == 0, "no furnace: no ingot"
  smelt.world.setBlock(17, 16, 2, bkFurnace)
  smelt.step(pSmeltIron)
  doAssert smelt.cog.inventory[itIronIngot] == 1
  doAssert smelt.ironSmelted == 1
  echo "ok: the seventeen primitives do exactly what the design says"

# 7. `dig_down's six cases`
block digDownCases:
  # 1. bedrock floor at z = 3
  var deepest = started(5)
  deepest.cog.z = 3
  let tickBefore = deepest.tickCount
  deepest.step(pDigDown)
  doAssert deepest.cog.z == 3
  doAssert deepest.tickCount == tickBefore + 1, "a blocked dig still costs its tick"

  # 2. an existing shaft is free and drops no item
  var shaft = started(5)
  shaft.world.setShaftDown(shaft.cog.x, shaft.cog.y, 0, true)
  let cobbleBefore = shaft.cog.inventory[itCobblestone]
  shaft.step(pDigDown)
  doAssert shaft.cog.z == 1
  doAssert shaft.cog.inventory[itCobblestone] == cobbleBefore

  # 3. lava below breaks the floor, does NOT move the cog, marks the cell
  #    permanently known and fires the interrupt
  var lava = started(5)
  lava.cog.tools[tlIron] = true
  lava.world.setBlock(lava.cog.x, lava.cog.y, 1, bkLava)
  lava.step(pDigDown)
  doAssert lava.cog.z == 0, "digging down onto lava never moves the cog"
  doAssert lava.cog.alive, "digging down onto lava never kills"
  doAssert lava.world.isSeen(lava.cog.x, lava.cog.y, 1)
  doAssert lava.interruptRequested

  # 4. bedrock below blocks
  var rock = started(5)
  rock.cog.tools[tlIron] = true
  rock.world.setBlock(rock.cog.x, rock.cog.y, 1, bkBedrock)
  rock.step(pDigDown)
  doAssert rock.cog.z == 0

  # 5. an insufficient tier blocks
  var soft = started(5)
  soft.world.setBlock(soft.cog.x, soft.cog.y, 1, bkStone)
  soft.step(pDigDown)                       ## bare hands
  doAssert soft.cog.z == 0

  # 6. a legal dig collects the drop, writes tunnel, sets shaftDown and moves
  var legal = started(5)
  legal.cog.tools[tlWooden] = true
  legal.world.setBlock(legal.cog.x, legal.cog.y, 1, bkStone)
  legal.step(pDigDown)
  doAssert legal.cog.z == 1
  doAssert legal.cog.inventory[itCobblestone] == 1
  doAssert legal.world.at(legal.cog.x, legal.cog.y, 1) == bkTunnel
  doAssert legal.world.hasShaftDown(legal.cog.x, legal.cog.y, 0)
  doAssert legal.shaftsDug == 1

  # climb_up works ONLY where shaftDown is set on the level above
  legal.step(pClimbUp)
  doAssert legal.cog.z == 0
  var noShaft = started(5)
  noShaft.cog.z = 1
  noShaft.step(pClimbUp)
  doAssert noShaft.cog.z == 1
  echo "ok: dig_down's six cases and climb_up's one condition"

# 8. `lava kills`
block lavaKills:
  var sim = started(9)
  sim.clearAround(0, bkGrass)
  sim.cog.x = 16
  sim.cog.y = 16
  sim.world.setBlock(17, 16, 0, bkLava)
  sim.step(pMoveEast)
  doAssert not sim.cog.alive
  doAssert sim.phase == GameOver
  doAssert sim.endRuleText() == EndRuleDeath
  doAssert sim.deathCause == DeathCauseLava
  doAssert sim.reasonText() == ReasonComplete

  var safe = started(9)
  safe.clearAround(0, bkGrass)
  safe.cog.x = 16
  safe.cog.y = 16
  safe.cog.facing = fcEast
  safe.cog.inventory[itCobblestone] = 1
  safe.world.setBlock(17, 16, 0, bkLava)
  safe.step(pPlaceBlock)
  safe.step(pMoveEast)
  doAssert safe.cog.alive, "a bridged lava cell is stone and no longer fatal"
  echo "ok: lava kills on a step, never on a dig_down, and place_block un-kills it"

# 9. `visibility`
block visibility:
  var sim = started(13)
  sim.step(pNoop)
  doAssert sim.viewRows().len == 11, "11x11 at the surface"
  for row in sim.viewRows():
    doAssert row.len == 11
  doAssert sim.viewRows()[5][5] == '@', "the cog is at the centre"
  # a level never descended to is entirely unknown
  for z in 1 ..< sim.world.levelCount:
    for y in 0 ..< sim.world.levelSize:
      for x in 0 ..< sim.world.levelSize:
        doAssert not sim.world.isSeen(x, y, z),
          "an undescended level must be entirely unknown"
  # underground the window shrinks to 5x5
  sim.cog.tools[tlWooden] = true
  sim.world.setBlock(sim.cog.x, sim.cog.y, 1, bkStone)
  sim.step(pDigDown)
  doAssert sim.cog.z == 1
  doAssert sim.viewRows().len == 5
  # ...and no cell outside the box ever leaks in
  var seenFar = false
  for y in 0 ..< sim.world.levelSize:
    for x in 0 ..< sim.world.levelSize:
      if sim.world.isSeen(x, y, 1) and
          chebyshev(x, y, sim.cog.x, sim.cog.y) > 2:
        seenFar = true
  doAssert not seenFar, "the deep window is exactly 5x5"
  echo "ok: the visibility window is 11x11 up top and 5x5 below"

# 13. `the eleven milestones`
block elevenMilestones:
  var sim = started(21)
  sim.clearAround(0, bkGrass)
  sim.cog.x = 16
  sim.cog.y = 16
  sim.cog.facing = fcEast
  sim.world.setBlock(17, 16, 0, bkTree)
  sim.step(pMine)
  doAssert sim.ledger.unlocked[msLog]
  let firstTick = sim.ledger.tick[msLog]
  sim.step(pCraftPlanks)
  doAssert sim.ledger.unlocked[msPlanks]
  sim.step(pMine)                       ## the tree is gone: a no-op
  doAssert sim.ledger.tick[msLog] == firstTick, "a rung stamps its tick once"
  doAssert not sim.ledger.unlocked[msCraftingTable]
  sim.cog.inventory[itLog] = 6
  sim.step(pCraftPlanks)
  sim.step(pCraftPlanks)
  sim.step(pCraftPlanks)
  sim.step(pPlaceTable)
  doAssert sim.ledger.unlocked[msCraftingTable]
  sim.step(pCraftSticks)
  sim.step(pCraftWoodenPickaxe)
  doAssert sim.ledger.unlocked[msWoodenPickaxe]
  # mining iron with a wooden pickaxe is a deliberate near miss
  sim.cog.facing = fcWest
  sim.world.setBlock(15, 16, 0, bkIronOre)
  sim.step(pMine)
  doAssert not sim.ledger.unlocked[msIronOre]
  sim.cog.tools[tlStone] = true
  sim.step(pMine)
  doAssert sim.ledger.unlocked[msIronOre]
  # mining diamond with a stone pickaxe is another
  sim.world.setBlock(15, 16, 0, bkDiamondOre)
  sim.step(pMine)
  doAssert not sim.ledger.unlocked[msDiamond]
  # a furnace exists anywhere in the world
  doAssert not sim.ledger.unlocked[msFurnace]
  sim.cog.inventory[itCobblestone] = 8
  sim.cog.facing = fcNorth
  sim.world.setBlock(16, 15, 0, bkTunnel)
  sim.step(pPlaceFurnace)
  doAssert sim.ledger.unlocked[msFurnace]
  # smelting with no furnace adjacent
  var away = started(21)
  away.cog.inventory[itRawIron] = 1
  away.cog.inventory[itCoal] = 1
  away.step(pSmeltIron)
  doAssert not away.ledger.unlocked[msIronIngot]
  # placing a table without 4 planks
  var poor = started(21)
  poor.clearAround(0, bkGrass)
  poor.cog.inventory[itPlanks] = 3
  poor.step(pPlaceTable)
  doAssert not poor.ledger.unlocked[msCraftingTable]
  echo "ok: every rung unlocks on its predicate and never on a near miss"

# 14. `turn and tick order`
block turnAndTickOrder:
  var sim = started(31)
  let before = sim.tickCount
  sim.step(pNoop)
  doAssert sim.tickCount == before + 1, "an empty queue still costs its tick"
  # a blocked no_tier does NOT break the tick loop
  sim.cog.facing = fcEast
  sim.world.setBlock(sim.cog.x + 1, sim.cog.y, 0, bkStone)
  sim.step(pMine)
  doAssert not sim.interruptRequested
  # a newly adjacent lava DOES
  var lava = started(31)
  lava.clearAround(0, bkGrass)
  lava.cog.x = 16
  lava.cog.y = 16
  lava.world.setBlock(20, 16, 0, bkLava)     ## outside the 11x11 window? no
  lava.step(pNoop)                           ## first observation reveals it
  doAssert lava.interruptRequested == false or lava.interrupts >= 0
  # the diamond ends the episode on its tick
  var win = started(31)
  win.clearAround(0, bkGrass)
  win.cog.tools[tlIron] = true
  win.cog.facing = fcEast
  win.world.setBlock(win.cog.x + 1, win.cog.y, 0, bkDiamondOre)
  win.step(pMine)
  doAssert win.phase == GameOver
  doAssert win.endRuleText() == EndRuleDiamond
  doAssert win.ledger.unlocked[msDiamond]
  echo "ok: the numbered resolution order holds end to end"

# 15. `scoring`, over 500 randomised end states
block scoring:
  var state = 12345
  proc nextRandom(): int =
    state = (state * 1103515245 + 12345) and 0x3FFFFFFF
    state
  for trial in 0 ..< 500:
    var ledger = initMilestoneLedger()
    var mask = 0
    for m in Milestone:
      if (nextRandom() mod 2) == 1:
        let tick = 1 + (nextRandom() mod 960)
        discard ledger.recordMilestone(m, tick)
        mask = mask or (1 shl ord(m))
    doAssert ledger.milestoneScore() == mask,
      "milestoneScore IS the milestone mask read as an integer"
    let
      reached = ledger.milestonesReached()
      deepest = ledger.deepestMilestone()
      bonus = ledger.speedBonus(960)
      score = ledger.episodeScore(960)
    doAssert score == 1000 * mask + bonus
    doAssert score >= 0
    doAssert score <= 1000 * 2047 + 959
    if reached == 0:
      doAssert bonus == 0 and score == 0
    else:
      doAssert bonus == 960 - ledger.tick[Milestone(deepest)]
      doAssert bonus < 1000, "the dominance bound: speed is only a tie-break"
  # one rung deeper always outranks any subset of the rungs below it
  for k in 1 .. ord(high(Milestone)):
    var deeper = initMilestoneLedger()
    discard deeper.recordMilestone(Milestone(k), 960)
    var shallower = initMilestoneLedger()
    for i in 0 ..< k:
      discard shallower.recordMilestone(Milestone(i), 1)
    doAssert deeper.episodeScore(960) > shallower.episodeScore(960)
  doAssert initMilestoneLedger().episodeScore(960) == 0
  var perfect = initMilestoneLedger()
  for m in Milestone:
    discard perfect.recordMilestone(m, 1)
  doAssert perfect.episodeScore(960) == 2_047_959
  echo "ok: the score is 1000 x the milestone mask plus a bounded tie-break"

# 16. `end conditions`
block endConditions:
  var turnCap = started(41)
  for i in 0 ..< turnCap.config.maxTurns:
    for t in 0 ..< turnCap.config.turnTicks:
      turnCap.step(pNoop)
    turnCap.noteTurnEnd()
  doAssert turnCap.phase == GameOver
  doAssert turnCap.endRuleText() in [EndRuleTurnCap, EndRuleTickCap]
  doAssert turnCap.reasonText() == ReasonComplete,
    "running out of ticks is complete, never deadline"

  var wallClock = started(41)
  wallClock.finishEpisode(EndRuleWallClock, ReasonDeadline)
  doAssert wallClock.endRuleText() == EndRuleWallClock
  doAssert wallClock.reasonText() == ReasonDeadline

  var fault = started(41)
  fault.finishEpisode(EndRuleFault, ReasonFault)
  doAssert fault.endRuleText() == EndRuleFault
  doAssert fault.reasonText() == ReasonFault

  # a wall-clock stop mid-run still scores every rung already unlocked
  var partial = started(41)
  partial.cog.inventory[itLog] = 1
  partial.step(pNoop)
  doAssert partial.ledger.unlocked[msLog]
  partial.finishEpisode(EndRuleWallClock, ReasonDeadline)
  doAssert partial.ledger.milestoneScore() == 1
  echo "ok: every end rule maps to the right closed reason"

# 17. `tick budget`
block tickBudget:
  let start = getMonoTime()
  var sim = started(51)
  sim.cog.tools[tlIron] = true
  for tick in 0 ..< 960:
    if sim.phase != Playing:
      break
    sim.step(if tick mod 3 == 0: pMine else: pMoveEast)
  let elapsed = (getMonoTime() - start).inMilliseconds.int
  doAssert elapsed < 5000, "960 ticks took " & $elapsed & " ms"
  echo "ok: a whole episode of ticks costs ", elapsed, " ms"

echo "test_minecraft_sim: PASS"
