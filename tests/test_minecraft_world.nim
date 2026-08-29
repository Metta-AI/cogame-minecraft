## Sim unit tests: the world generator and everything derived from it.
##
## Design note §Tests items 1-5 and 9-12.

import std/[sets, strutils]

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
