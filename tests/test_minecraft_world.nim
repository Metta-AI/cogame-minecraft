## Sim unit tests: the world generator and everything derived from it.
##
## Design note §Tests items 1-5 and 9-12.

import std/[heapqueue, sets, strutils]

import minecraft/sim

proc standardConfig(seed: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed

proc deepcutConfig(seed: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.variant = "deepcut"
  result.maxTurns = 32
  result.maxTicks = 640
  result.lavaChanceIron = 18
  result.lavaChanceDiamond = 45
  result.coalChanceStone = 270
  result.coalChanceIron = 120
  result.ironChanceIron = 210
  result.ironChanceDiamond = 165
  result.diamondChance = 105
  result.parMilestones = 5

proc countOf(world: World, z: int, kind: Block): int =
  for y in 1 ..< world.levelSize - 1:
    for x in 1 ..< world.levelSize - 1:
      if world.at(x, y, z) == kind:
        inc result

# 1. `world is a pure function of the seed`
block pureFunctionOfSeed:
  let config = standardConfig(1234)
  let a = generateWorld(config)
  # Three different "policy behaviours": generate before, between and after
  # unrelated work, and with an interleaved second world.
  let other = generateWorld(standardConfig(9999))
  let b = generateWorld(config)
  var scratch = generateWorld(config)
  scratch.setBlock(5, 5, 0, bkLava)          ## a policy mutating its own copy
  let c = generateWorld(config)
  doAssert a.cells == b.cells
  doAssert a.cells == c.cells
  doAssert a.shaftDown == b.shaftDown
  doAssert a.cells != other.cells
  echo "ok: the world is a pure function of (seed, variant)"

# 2. `generation invariants`, over 200 seeds and both variants
block generationInvariants:
  for seed in 1 .. 200:
    for config in [standardConfig(seed), deepcutConfig(seed)]:
      let world = generateWorld(config)
      let spawn = world.spawnCell()
      let size = world.levelSize
      # the bedrock ring is intact and unbroken on every level
      for z in 0 ..< world.levelCount:
        for i in 0 ..< size:
          doAssert world.at(i, 0, z) == bkBedrock
          doAssert world.at(i, size - 1, z) == bkBedrock
          doAssert world.at(0, i, z) == bkBedrock
          doAssert world.at(size - 1, i, z) == bkBedrock
      # the 3x3 block at spawn is grass and the cell below it is stone
      for dy in -1 .. 1:
        for dx in -1 .. 1:
          doAssert world.at(spawn.x + dx, spawn.y + dy, 0) == bkGrass
      doAssert world.at(spawn.x, spawn.y, 1) == bkStone
      # a tree within Chebyshev 8 of spawn, and at least six on the surface
      var nearTree = false
      for y in 1 ..< size - 1:
        for x in 1 ..< size - 1:
          if world.at(x, y, 0) == bkTree and
              chebyshev(x, y, spawn.x, spawn.y) <= 8:
            nearTree = true
      doAssert nearTree, "no tree within Chebyshev 8 of spawn, seed " & $seed
      doAssert world.countOf(0, bkTree) >= 6
      # the five global minima
      doAssert world.countOf(1, bkCoalOre) >= config.minCoalStone
      doAssert world.countOf(2, bkIronOre) >= config.minIronIron
      doAssert world.countOf(2, bkCoalOre) >= config.minCoalIron
      doAssert world.countOf(3, bkDiamondOre) >= config.minDiamond
      doAssert world.countOf(3, bkIronOre) >= config.minIronDiamond
      # each of z in {2, 3} has at least 700 non-bedrock non-lava cells
      for z in 2 .. 3:
        var diggable = 0
        for y in 1 ..< size - 1:
          for x in 1 ..< size - 1:
            if world.at(x, y, z) != bkLava:
              inc diggable
        doAssert diggable >= 700, "level " & $z & " is sealed, seed " & $seed
  echo "ok: generation invariants hold over 200 seeds of both variants"

# 3. `the world is completable` - a reference solver that ignores the turn
#    budget reaches every ore it needs on every committed seed.
block worldIsCompletable:
  proc reachable(world: World, z: int, target: Block): bool =
    ## Flood the level from a start cell through everything a full-tier cog can
    ## tunnel through (anything that is not bedrock and not lava), and report
    ## whether it touches the target block. That is the reference solver:
    ## with the iron pickaxe every non-bedrock non-lava cell is mineable.
    let size = world.levelSize
    var
      seen = newSeq[bool](size * size)
      queue = @[(size div 2) * size + (size div 2)]
    seen[queue[0]] = true
    var head = 0
    while head < queue.len:
      let
        current = queue[head]
        cx = current mod size
        cy = current div size
      inc head
      if world.at(cx, cy, z) == target:
        return true
      for facing in Neighbours:
        let
          nx = cx + facing.dx()
          ny = cy + facing.dy()
        if nx < 0 or ny < 0 or nx >= size or ny >= size:
          continue
        let next = ny * size + nx
        if seen[next]:
          continue
        let cell = world.at(nx, ny, z)
        if cell == bkBedrock or cell == bkLava:
          continue
        seen[next] = true
        queue.add(next)
    false

  for seed in 1 .. 60:
    for config in [standardConfig(seed), deepcutConfig(seed)]:
      let world = generateWorld(config)
      doAssert world.reachable(0, bkTree), "no reachable tree, seed " & $seed
      doAssert world.reachable(1, bkCoalOre), "no reachable coal, seed " & $seed
      doAssert world.reachable(2, bkIronOre), "no reachable iron, seed " & $seed
      doAssert world.reachable(3, bkDiamondOre),
        "no reachable diamond, seed " & $seed
  echo "ok: every seed is completable (60 seeds, both variants)"

# 3 (continued). `the reference solver's TICK COUNT`
#
# Reachability says the diamond exists behind diggable rock. What makes the
# 960 / 640 deadlines honest is how many TICKS an omniscient player needs, so
# the solver below actually plays the ladder: it knows the whole world (it
# reads `sim.world` directly, which no policy can, and no visibility rule
# applies to it) and it ignores the turn budget, but every action it takes is
# a real primitive through the real `sim.step`, so its tick count is a tick
# count this game can produce.
block referenceSolverTickCount:
  const
    MineCost = 3            ## turn, mine, step: the worst case per mined cell
    WalkCost = 1

  proc facingTo(fromX, fromY, toX, toY: int): Facing =
    if toX > fromX: fcEast
    elif toX < fromX: fcWest
    elif toY > fromY: fcSouth
    else: fcNorth

  proc costs(world: World, z, sx, sy, tier: int): tuple[cost: seq[int],
      prev: seq[int]] =
    ## Dijkstra over the TRUE grid of one level. Entering a walkable cell
    ## costs one tick; entering a cell this tier can mine costs three (turn,
    ## mine, step). Lava, water, bedrock, a table and a furnace are never
    ## entered.
    let size = world.levelSize
    result.cost = newSeq[int](size * size)
    result.prev = newSeq[int](size * size)
    for i in 0 ..< result.cost.len:
      result.cost[i] = high(int)
      result.prev[i] = -1
    var queue = initHeapQueue[(int, int)]()
    result.cost[sy * size + sx] = 0
    queue.push((0, sy * size + sx))
    while queue.len > 0:
      let (spent, index) = queue.pop()
      if spent > result.cost[index]:
        continue
      let
        cx = index mod size
        cy = index div size
      for facing in Neighbours:
        let
          nx = cx + facing.dx()
          ny = cy + facing.dy()
        if not world.inBounds(nx, ny, z):
          continue
        let cell = world.at(nx, ny, z)
        var step = -1
        if cell == bkLava:
          continue
        elif cell.walkable():
          step = WalkCost
        elif cell.mineTier() >= 0 and cell.mineTier() <= tier:
          step = MineCost
        if step < 0:
          continue
        let next = ny * size + nx
        if spent + step < result.cost[next]:
          result.cost[next] = spent + step
          result.prev[next] = index
          queue.push((spent + step, next))

  proc walkTo(sim: var SimServer, tx, ty: int): bool =
    ## Walks (mining where it must) to (tx, ty) on the cog's level.
    let size = sim.world.levelSize
    let found = sim.world.costs(sim.cog.z, sim.cog.x, sim.cog.y, sim.cog.tier())
    if found.cost[ty * size + tx] == high(int):
      return false
    var path: seq[int] = @[]
    var cursor = ty * size + tx
    while cursor != sim.cog.y * size + sim.cog.x:
      path.add(cursor)
      cursor = found.prev[cursor]
      if cursor < 0:
        return false
    for i in countdown(path.high, 0):
      let
        nx = path[i] mod size
        ny = path[i] div size
        facing = facingTo(sim.cog.x, sim.cog.y, nx, ny)
      if not sim.world.at(nx, ny, sim.cog.z).walkable():
        if sim.cog.facing != facing:
          sim.step(facing.moveOf())       ## a blocked move is a TURN
        sim.step(pMine)
        if sim.phase != Playing:
          return true                     ## the diamond ends the episode
      sim.step(facing.moveOf())
      if sim.phase != Playing:
        return true
      if sim.cog.x != nx or sim.cog.y != ny:
        return false
    true

  proc walkInto(sim: var SimServer, kind: Block): bool =
    ## Walks into the cheapest cell of `kind` on this level, which mines it.
    let size = sim.world.levelSize
    let found = sim.world.costs(sim.cog.z, sim.cog.x, sim.cog.y, sim.cog.tier())
    var
      best = high(int)
      bestIndex = -1
    for y in 1 ..< size - 1:
      for x in 1 ..< size - 1:
        if sim.world.at(x, y, sim.cog.z) != kind:
          continue
        let index = y * size + x
        if found.cost[index] < best:
          best = found.cost[index]
          bestIndex = index
    if bestIndex < 0:
      return false
    sim.walkTo(bestIndex mod size, bestIndex div size)

  proc turned(facing: Facing): Facing =
    case facing
    of fcEast: fcSouth
    of fcSouth: fcWest
    of fcWest: fcNorth
    of fcNorth: fcEast

  proc lavaAt(sim: SimServer, facing: Facing): bool =
    sim.world.at(sim.cog.x + facing.dx(), sim.cog.y + facing.dy(),
      sim.cog.z) == bkLava

  proc placeAhead(sim: var SimServer, primitive: Primitive): bool =
    ## Places a table or a furnace in whichever neighbour will take it,
    ## cutting one out of the rock if none will. It never turns towards lava:
    ## `move_<dir>` sets the facing AND steps when the cell is walkable, and
    ## lava is walkable - that is how you die.
    let kind = if primitive == pPlaceTable: bkTable else: bkFurnace
    if sim.world.adjacentHas(sim.cog, kind):
      return true
    for _ in 0 ..< 6:
      let ahead = sim.cog.aheadCell()
      let cell = sim.world.at(ahead.x, ahead.y, ahead.z)
      if cell in {bkGrass, bkSand, bkTunnel}:
        sim.step(primitive)
        if sim.world.adjacentHas(sim.cog, kind):
          return true
      elif cell != bkLava and cell.mineTier() >= 0 and
          cell.mineTier() <= sim.cog.tier():
        sim.step(pMine)                 ## cut a socket for it
        sim.step(primitive)
        if sim.world.adjacentHas(sim.cog, kind):
          return true
      var next = sim.cog.facing.turned()
      var guard = 0
      while guard < 3 and sim.lavaAt(next):
        next = next.turned()
        inc guard
      if sim.lavaAt(next):
        return false
      sim.step(next.moveOf())
      if sim.phase != Playing:
        return false
    false

  proc descend(sim: var SimServer): bool =
    ## Digs down from here, or from the nearest cell that will take a shaft.
    let z = sim.cog.z
    sim.step(pDigDown)
    if sim.cog.z > z:
      return true
    let size = sim.world.levelSize
    let found = sim.world.costs(z, sim.cog.x, sim.cog.y, sim.cog.tier())
    var
      best = high(int)
      bestIndex = -1
    for y in 1 ..< size - 1:
      for x in 1 ..< size - 1:
        let below = sim.world.at(x, y, z + 1)
        if below == bkLava or below.mineTier() < 0 or
            below.mineTier() > sim.cog.tier():
          continue
        if not sim.world.at(x, y, z).walkable():
          continue
        let index = y * size + x
        if found.cost[index] < best:
          best = found.cost[index]
          bestIndex = index
    if bestIndex < 0:
      return false
    if not sim.walkTo(bestIndex mod size, bestIndex div size):
      return false
    sim.step(pDigDown)
    sim.cog.z > z

  proc solve(config: GameConfig): tuple[ok: bool, ticks: int] =
    ## The ladder, rung by rung, with full knowledge and no turn budget.
    var wide = config
    wide.maxTicks = 100_000          ## "ignores the turn budget"
    wide.maxTurns = 100_000
    var sim = initSimServer(wide)
    sim.startGame()
    # 19 planks (three tables and a wooden pickaxe) plus 4 for the sticks:
    # six logs is two trees.
    for _ in 0 ..< 2:
      if not sim.walkInto(bkTree):
        return (false, sim.gameTicksElapsed())
    for _ in 0 ..< 5:
      sim.step(pCraftPlanks)
    for _ in 0 ..< 2:
      sim.step(pCraftSticks)
    if not sim.placeAhead(pPlaceTable):
      return (false, sim.gameTicksElapsed())
    sim.step(pCraftWoodenPickaxe)
    if not sim.cog.tools[tlWooden] or not sim.descend():
      return (false, sim.gameTicksElapsed())
    # y=48: eleven cobblestone (a furnace and a stone pickaxe) and three coal.
    while sim.cog.inventory[itCobblestone] < 11:
      if not sim.walkInto(bkStone):
        return (false, sim.gameTicksElapsed())
    while sim.cog.inventory[itCoal] < 3:
      if not sim.walkInto(bkCoalOre):
        return (false, sim.gameTicksElapsed())
    if not sim.placeAhead(pPlaceTable):
      return (false, sim.gameTicksElapsed())
    sim.step(pCraftStonePickaxe)
    if not sim.cog.tools[tlStone] or not sim.descend():
      return (false, sim.gameTicksElapsed())
    # y=32: three iron ore, a furnace, three ingots, a table, the iron pickaxe.
    while sim.cog.inventory[itRawIron] < 3:
      if not sim.walkInto(bkIronOre):
        return (false, sim.gameTicksElapsed())
    if not sim.placeAhead(pPlaceFurnace):
      return (false, sim.gameTicksElapsed())
    for _ in 0 ..< 3:
      sim.step(pSmeltIron)
    if not sim.placeAhead(pPlaceTable):
      return (false, sim.gameTicksElapsed())
    sim.step(pCraftIronPickaxe)
    if not sim.cog.tools[tlIron] or not sim.descend():
      return (false, sim.gameTicksElapsed())
    # y=12: the diamond.
    if not sim.walkInto(bkDiamondOre):
      return (false, sim.gameTicksElapsed())
    (sim.ledger.unlocked[msDiamond], sim.gameTicksElapsed())

  var
    worstStandard = 0
    worstDeepcut = 0
  for seed in 1 .. 60:
    let standard = solve(standardConfig(seed))
    doAssert standard.ok,
      "the reference solver did not reach the diamond on standard seed " &
      $seed & " (gave up after " & $standard.ticks & " ticks)"
    doAssert standard.ticks <= 500,
      "the reference solver needed " & $standard.ticks & " ticks on standard " &
      "seed " & $seed & ": the 960-tick deadline is not honest"
    worstStandard = max(worstStandard, standard.ticks)
    let deep = solve(deepcutConfig(seed))
    doAssert deep.ok,
      "the reference solver did not reach the diamond on deepcut seed " & $seed
    doAssert deep.ticks <= 420,
      "the reference solver needed " & $deep.ticks & " ticks on deepcut seed " &
      $seed & ": the 640-tick deadline is not honest"
    worstDeepcut = max(worstDeepcut, deep.ticks)
  echo "ok: the reference solver reaches the diamond on 60 seeds of both ",
    "variants in at most ", worstStandard, " ticks (standard, cap 500) and ",
    worstDeepcut, " (deepcut, cap 420)"

# 4. `noise is integer`
block noiseIsInteger:
  # A second, independent implementation of the lattice interpolation,
  # compared cell for cell.
  proc referenceField(seed, salt, x, y: int): int =
    let
      stride = 8
      gx = x div stride
      gy = y div stride
      tx = x mod stride
      ty = y mod stride
    proc corner(cx, cy: int): int = mix64(seed, salt, cx, cy) mod 1024
    let
      v00 = corner(gx, gy)
      v10 = corner(gx + 1, gy)
      v01 = corner(gx, gy + 1)
      v11 = corner(gx + 1, gy + 1)
      fx = (tx * 65536) div stride
      fy = (ty * 65536) div stride
      top = v00 + ((v10 - v00) * fx) div 65536
      bottom = v01 + ((v11 - v01) * fx) div 65536
    top + ((bottom - top) * fy) div 65536

  for z in 0 .. 3:
    for f in 0 .. 2:
      let salt = 1 + 3 * z + f
      for y in 0 ..< 32:
        for x in 0 ..< 32:
          let got = noiseField(4242, salt, x, y)
          doAssert got == referenceField(4242, salt, x, y),
            "noise mismatch at " & $x & "," & $y
          doAssert got >= 0 and got <= 1023
  echo "ok: the noise fields are integer and match a second implementation"

# 4b. `every integer the sim computes fits a 32-BIT int`
block wasm32Safety:
  ## The sim compiles twice: natively (64-bit `int`) and to wasm32, where
  ## `int` is THIRTY-TWO bits and a conversion that overflows raises `value
  ## out of range` at run time. That failure is invisible to a native test
  ## suite and kills the hosted viewer on its first frame with every asset
  ## 200 (run 33241005565). These are the quantities a policy or a seed can
  ## push.
  const Int32Max = 2_147_483_647
  for seed in [1, 42, 0xA6019, 2_147_483_646]:
    for salt in 0 .. 20:
      for x in 0 ..< 40:
        for y in 0 ..< 40:
          let draw = mix64(seed, salt, x, y)
          doAssert draw >= 0, "mix64 must be non-negative"
          doAssert draw <= Mix64Mask, "mix64 must fit 30 bits, got " & $draw
          doAssert draw <= Int32Max
          let field = noiseField(seed, salt, x, y)
          doAssert field >= 0 and field <= 1023
  # the interpolation's widest intermediate: 1023 * 65536
  doAssert 1023 * 65536 <= Int32Max
  # the widest score the game can produce
  doAssert 1000 * 2047 + 959 <= Int32Max
  # every cell index of the biggest legal world
  doAssert 8 * 64 * 64 <= Int32Max
  echo "ok: every generated integer fits a 32-bit int (wasm32 is int32)"

# 5. `glyph, walkable, tier and drop tables are total`
block tablesAreTotal:
  var glyphs = initHashSet[char]()
  for b in Block:
    doAssert b.glyph() notin glyphs, "duplicate glyph " & $b.glyph()
    glyphs.incl(b.glyph())
    discard b.walkable()
    discard b.mineTier()
    discard b.dropOf()
    discard b.becomes()
  doAssert glyphs.len == 13
  # the whole seventeen-glyph vocabulary: 13 blocks + v + ^ + @ + ?
  for extra in ['v', '^', '@', '?']:
    doAssert extra notin glyphs
  doAssert bkGrass.walkable() and bkSand.walkable() and bkTunnel.walkable()
  doAssert bkLava.walkable()          ## lava IS walkable - that is how you die
  doAssert not bkWater.walkable() and not bkStone.walkable()
  doAssert bkTree.mineTier() == 0
  doAssert bkStone.mineTier() == 1 and bkCoalOre.mineTier() == 1
  doAssert bkIronOre.mineTier() == 2
  doAssert bkDiamondOre.mineTier() == 3
  doAssert bkBedrock.mineTier() == -1 and bkLava.mineTier() == -1
  doAssert bkTree.dropOf() == (true, itLog, 3)
  doAssert bkStone.dropOf() == (true, itCobblestone, 1)
  doAssert bkTree.becomes() == bkGrass
  doAssert bkCoalOre.becomes() == bkTunnel
  echo "ok: the block tables are total and the glyphs are pairwise distinct"

# 10. `the 16 x 16 region map`
block regionMap:
  var sim = initSimServer(standardConfig(7))
  sim.startGame()
  for i in 0 ..< 40:
    sim.step(pNoop)
  let rows = sim.world.regionMap(sim.cog.z, sim.config.regionSize,
    sim.cog.x, sim.cog.y)
  doAssert rows.len == 16
  for row in rows:
    doAssert row.len == 16
    for ch in row:
      doAssert ch in ".,~T#ciD=!Btfv^@?", "unexpected region glyph " & $ch
  var unseenRegions = 0
  for row in rows:
    for ch in row:
      if ch == '?':
        inc unseenRegions
  doAssert unseenRegions > 0, "a fresh run cannot know the whole level"
  echo "ok: the region map is 16 strings of 16, current level only"

# 11. `goto BFS`
block gotoBfs:
  var sim = initSimServer(standardConfig(11))
  sim.startGame()
  sim.step(pNoop)
  let spawn = sim.world.spawnCell()
  # An unreachable target (never seen) yields zero primitives.
  doAssert sim.world.bfsPath(spawn.x, spawn.y, 0, 1, 1, 20).len == 0
  # A traversable target one step away ends ON it.
  let east = sim.world.bfsPath(spawn.x, spawn.y, 0, spawn.x + 1, spawn.y, 20)
  doAssert east.len == 1 and east[0] == fcEast
  # The path is unique for a given known map: two runs agree.
  let again = sim.world.bfsPath(spawn.x, spawn.y, 0, spawn.x + 1, spawn.y, 20)
  doAssert east == again
  # It never exceeds the cap.
  let capped = sim.world.bfsPath(spawn.x, spawn.y, 0, spawn.x + 5, spawn.y, 3)
  doAssert capped.len <= 3
  echo "ok: the goto BFS is deterministic, bounded and never enters the unknown"

echo "test_minecraft_world: PASS"
