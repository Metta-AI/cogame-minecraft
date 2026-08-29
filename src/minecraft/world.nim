## The four-level blocky world: the seeded integer value-noise generator, the
## playability post-pass, the grid type, the shaft planes, the depth-dependent
## visibility window, the 16x16 region downsample and the 4-adjacency BFS the
## `goto` macro and the `miner` baseline both route through.
##
## INTEGER ONLY. There is no floating point anywhere in this module - the noise
## lattice interpolates in 16-bit fixed point - so every field is bit-identical
## native and in wasm, which is what makes the replay's per-tick hash chain
## re-derivable in the browser.

import std/[algorithm, heapqueue]

import sim_types

type
  World* = object
    ## `levelCount` stacked `levelSize` x `levelSize` grids, plus the shaft
    ## planes that are the only vertical connection between them.
    levelCount*: int
    levelSize*: int
    cells*: seq[Block]        ## z-major, then y, then x
    shaftDown*: seq[bool]     ## same indexing; true where a dig_down cut through
    seen*: seq[bool]          ## per cell, has the cog ever observed it
    seenTick*: seq[int32]     ## the tick it was last observed, or 0
    known*: seq[Block]        ## last observed block (meaningless while unseen)

  Cell* = object
    x*, y*, z*: int

proc cellIndex*(world: World, x, y, z: int): int {.inline.} =
  (z * world.levelSize + y) * world.levelSize + x

proc inBounds*(world: World, x, y, z: int): bool {.inline.} =
  x >= 0 and y >= 0 and z >= 0 and x < world.levelSize and
    y < world.levelSize and z < world.levelCount

proc at*(world: World, x, y, z: int): Block {.inline.} =
  if not world.inBounds(x, y, z):
    return bkBedrock
  world.cells[world.cellIndex(x, y, z)]

proc setBlock*(world: var World, x, y, z: int, value: Block) {.inline.} =
  if world.inBounds(x, y, z):
    world.cells[world.cellIndex(x, y, z)] = value

proc hasShaftDown*(world: World, x, y, z: int): bool {.inline.} =
  if not world.inBounds(x, y, z):
    return false
  world.shaftDown[world.cellIndex(x, y, z)]

proc setShaftDown*(world: var World, x, y, z: int, value: bool) {.inline.} =
  if world.inBounds(x, y, z):
    world.shaftDown[world.cellIndex(x, y, z)] = value

proc isSeen*(world: World, x, y, z: int): bool {.inline.} =
  if not world.inBounds(x, y, z):
    return false
  world.seen[world.cellIndex(x, y, z)]

proc knownAt*(world: World, x, y, z: int): Block {.inline.} =
  world.known[world.cellIndex(x, y, z)]

proc isRing*(world: World, x, y: int): bool {.inline.} =
  ## The outermost ring of every level is bedrock, so the cog can never leave
  ## the world and no generator needs an out-of-bounds branch.
  x == 0 or y == 0 or x == world.levelSize - 1 or y == world.levelSize - 1

# ---------------------------------------------------------------------------
#  Integer value noise
# ---------------------------------------------------------------------------

const NoiseStride = 8

const LavaCaveGate* = 300
  ## Rule 2's cave gate: a cell is a candidate for lava only where the cave
  ## field is below this. The design note writes 120; at 120 the product with
  ## a 12-45 permille draw put 0.11 lava cells on z=2 and 0.38 on z=3, and
  ## 68 % of standard seeds had no lava anywhere, which made the game's only
  ## lethal thing unreachable (docs/PORTING-MINECRAFT.md, divergence C).

proc latticeValue(seed, salt, gx, gy: int): int =
  ## A lattice corner: `mix64(seed, fieldSalt, gx, gy) mod 1024`.
  mix64(seed, salt, gx, gy) mod 1024

proc noiseField*(seed, salt, x, y: int): int =
  ## Bilinear interpolation of the stride-8 lattice in 16-bit fixed point.
  ## Returns 0 .. 1023.
  let
    gx = x div NoiseStride
    gy = y div NoiseStride
    fx = ((x mod NoiseStride) * 65536) div NoiseStride
    fy = ((y mod NoiseStride) * 65536) div NoiseStride
    v00 = latticeValue(seed, salt, gx, gy)
    v10 = latticeValue(seed, salt, gx + 1, gy)
    v01 = latticeValue(seed, salt, gx, gy + 1)
    v11 = latticeValue(seed, salt, gx + 1, gy + 1)
    top = v00 + ((v10 - v00) * fx) div 65536
    bottom = v01 + ((v11 - v01) * fx) div 65536
  top + ((bottom - top) * fy) div 65536

proc fieldSalt(z, f: int): int {.inline.} =
  1 + 3 * z + f

proc draw(seed, z, k, x, y: int): int {.inline.} =
  ## A per-cell chance draw, 0 .. 999, with a distinct `k` per ore.
  mix64(seed, 40 + 4 * z + k, x, y) mod 1000

# ---------------------------------------------------------------------------
#  Generation
# ---------------------------------------------------------------------------

proc caveThresholdFor(config: GameConfig, z: int): int =
  case z
  of 1: config.caveThresholdStone
  of 2: config.caveThresholdIron
  else: config.caveThresholdDiamond

proc lavaChanceFor(config: GameConfig, z: int): int =
  case z
  of 2: config.lavaChanceIron
  of 3: config.lavaChanceDiamond
  else: 0

proc oreAFor(config: GameConfig, z: int): tuple[b: Block, chance: int] =
  case z
  of 1: (bkCoalOre, config.coalChanceStone)
  of 2: (bkIronOre, config.ironChanceIron)
  else: (bkDiamondOre, config.diamondChance)

proc oreBFor(config: GameConfig, z: int): tuple[b: Block, chance: int] =
  case z
  of 1: (bkCoalOre, 0)
  of 2: (bkCoalOre, config.coalChanceIron)
  else: (bkIronOre, config.ironChanceDiamond)

proc countBlock(world: World, z: int, kind: Block): int =
  for y in 1 ..< world.levelSize - 1:
    for x in 1 ..< world.levelSize - 1:
      if world.at(x, y, z) == kind:
        inc result

proc chebyshev*(ax, ay, bx, by: int): int {.inline.} =
  max(abs(ax - bx), abs(ay - by))

proc treeWithin(world: World, cx, cy, radius: int): bool =
  for y in max(1, cy - radius) .. min(world.levelSize - 2, cy + radius):
    for x in max(1, cx - radius) .. min(world.levelSize - 2, cx + radius):
      if world.at(x, y, 0) == bkTree:
        return true
  false

proc promoteStone(world: var World, seed, z: int, target: Block, minimum: int) =
  ## Converts the `stone` cell with the highest `vein` value into `target`
  ## until at least `minimum` of them exist. Ties break by ascending (y, x),
  ## so the pass is deterministic.
  var have = world.countBlock(z, target)
  while have < minimum:
    var
      bestX = -1
      bestY = -1
      bestValue = -1
    for y in 1 ..< world.levelSize - 1:
      for x in 1 ..< world.levelSize - 1:
        if world.at(x, y, z) != bkStone:
          continue
        let value = noiseField(seed, fieldSalt(z, 1), x, y)
        if value > bestValue:
          bestValue = value
          bestX = x
          bestY = y
    if bestX < 0:
      break
    world.setBlock(bestX, bestY, z, target)
    inc have

proc unsealLava(world: var World, seed, z, floorCells: int) =
  ## No lava seals a level: convert the `lava` cells with the highest `cave`
  ## value back to `stone` until at least `floorCells` interior cells are
  ## neither bedrock nor lava.
  while true:
    var diggable = 0
    for y in 1 ..< world.levelSize - 1:
      for x in 1 ..< world.levelSize - 1:
        if world.at(x, y, z) != bkLava:
          inc diggable
    if diggable >= floorCells:
      break
    var
      bestX = -1
      bestY = -1
      bestValue = -1
    for y in 1 ..< world.levelSize - 1:
      for x in 1 ..< world.levelSize - 1:
        if world.at(x, y, z) != bkLava:
          continue
        let value = noiseField(seed, fieldSalt(z, 0), x, y)
        if value > bestValue:
          bestValue = value
          bestX = x
          bestY = y
    if bestX < 0:
      break
    world.setBlock(bestX, bestY, z, bkStone)

proc openSurfaceRoute(world: var World, spawnX, spawnY: int) =
  ## Post-pass 2b: GUARANTEE A TIER-0 ROUTE TO WOOD.
  ##
  ## Wood exists only on the surface and nothing underground can be reached
  ## without it: no log, no planks, no wooden pickaxe, and `dig_down` refuses
  ## the stone under spawn for want of a tier. A spawn ringed by water (which
  ## is neither walkable nor mineable) is therefore a DEAD SEED that scores
  ## zero for every policy, and 35 of 300 standard seeds were exactly that.
  ## The note's own promise is "every seed is completable".
  ##
  ## If no tree is reachable from spawn through walkable cells, the cheapest
  ## route to one - fewest blocking cells, then the lowest cell index, so it
  ## is deterministic - has its water turned to sand and its rock to grass.
  ## Nothing else on the surface is touched, and the pass does nothing at all
  ## on a seed that already has a route.
  const Passable = {bkGrass, bkSand, bkTunnel}
  let size = world.levelSize
  var
    cost = newSeq[int](size * size)
    prev = newSeq[int](size * size)
  for i in 0 ..< cost.len:
    cost[i] = high(int)
    prev[i] = -1
  var queue = initHeapQueue[(int, int)]()
  let start = spawnY * size + spawnX
  cost[start] = 0
  queue.push((0, start))
  var
    bestTree = -1
    bestCost = high(int)
  while queue.len > 0:
    let (spent, index) = queue.pop()
    if spent > cost[index]:
      continue
    let
      cx = index mod size
      cy = index div size
    if world.at(cx, cy, 0) == bkTree and spent < bestCost:
      bestCost = spent
      bestTree = index
      if spent == 0:
        break                     ## already reachable: change nothing
    for facing in [fcNorth, fcEast, fcSouth, fcWest]:
      let
        nx = cx + facing.dx()
        ny = cy + facing.dy()
      if nx < 1 or ny < 1 or nx >= size - 1 or ny >= size - 1:
        continue
      let cell = world.at(nx, ny, 0)
      if cell == bkBedrock:
        continue
      ## A tree is the destination and costs nothing to stand beside; water
      ## and rock are what the route has to open.
      let step = if cell in Passable or cell == bkTree: 0 else: 1
      let next = ny * size + nx
      if spent + step < cost[next]:
        cost[next] = spent + step
        prev[next] = index
        queue.push((spent + step, next))
  if bestTree < 0 or bestCost == 0:
    return
  var cursor = bestTree
  while cursor >= 0 and cursor != start:
    let
      cx = cursor mod size
      cy = cursor div size
      cell = world.at(cx, cy, 0)
    if cell == bkWater:
      world.setBlock(cx, cy, 0, bkSand)
    elif cell notin Passable and cell != bkTree:
      world.setBlock(cx, cy, 0, bkGrass)
    cursor = prev[cursor]

proc spawnCell*(world: World): Cell =
  Cell(x: world.levelSize div 2, y: world.levelSize div 2, z: 0)

proc generateWorld*(config: GameConfig): World =
  ## The world is a pure function of `(seed, variant)`; the seat is never told
  ## any of it.
  let
    size = config.levelSize
    levels = config.levelCount
    seed = config.seed
    total = levels * size * size
  result.levelCount = levels
  result.levelSize = size
  result.cells = newSeq[Block](total)
  result.shaftDown = newSeq[bool](total)
  result.seen = newSeq[bool](total)
  result.seenTick = newSeq[int32](total)
  result.known = newSeq[Block](total)

  for z in 0 ..< levels:
    for y in 0 ..< size:
      for x in 0 ..< size:
        if result.isRing(x, y):
          result.setBlock(x, y, z, bkBedrock)
          continue
        if z == 0:
          let
            w = noiseField(seed, fieldSalt(0, 0), x, y)
            t = noiseField(seed, fieldSalt(0, 1), x, y)
            h = noiseField(seed, fieldSalt(0, 2), x, y)
          if w > 700:
            result.setBlock(x, y, z, bkWater)
          elif w > 650:
            result.setBlock(x, y, z, bkSand)
          elif t > 660:
            result.setBlock(x, y, z, bkTree)
          elif h > 900:
            result.setBlock(x, y, z, bkStone)
          else:
            result.setBlock(x, y, z, bkGrass)
        else:
          let
            c = noiseField(seed, fieldSalt(z, 0), x, y)
            v = noiseField(seed, fieldSalt(z, 1), x, y)
            oreA = oreAFor(config, z)
            oreB = oreBFor(config, z)
          if c > caveThresholdFor(config, z):
            result.setBlock(x, y, z, bkTunnel)
          elif c < LavaCaveGate and draw(seed, z, 0, x, y) <
              lavaChanceFor(config, z):
            result.setBlock(x, y, z, bkLava)
          elif v > config.veinThreshold and
              draw(seed, z, 1, x, y) < oreA.chance:
            result.setBlock(x, y, z, oreA.b)
          elif v > config.veinThreshold and
              draw(seed, z, 2, x, y) < oreB.chance:
            result.setBlock(x, y, z, oreB.b)
          else:
            result.setBlock(x, y, z, bkStone)

  # --- the playability post-pass, in this exact order ----------------------
  let spawn = result.spawnCell()

  # 1. The 3x3 block centred on spawn is grass.
  for y in spawn.y - 1 .. spawn.y + 1:
    for x in spawn.x - 1 .. spawn.x + 1:
      if not result.isRing(x, y):
        result.setBlock(x, y, 0, bkGrass)

  # 2. Wood exists only on the surface, so a wood-poor seed is a dead seed.
  if not result.treeWithin(spawn.x, spawn.y, 8):
    block plantNear:
      for y in 1 ..< size - 1:
        for x in 1 ..< size - 1:
          if chebyshev(x, y, spawn.x, spawn.y) == 5 and
              result.at(x, y, 0) == bkGrass:
            result.setBlock(x, y, 0, bkTree)
            break plantNear
  while result.countBlock(0, bkTree) < 6:
    var planted = false
    block plantAny:
      for y in 1 ..< size - 1:
        for x in 1 ..< size - 1:
          if result.at(x, y, 0) != bkGrass:
            continue
          if chebyshev(x, y, spawn.x, spawn.y) <= 1:
            ## Never plant inside the forced grass 3x3 of post-pass 1: a tree
            ## on the spawn cell would break the invariant the note states
            ## one paragraph above (and tests/test_minecraft_world.nim
            ## asserts) - that the whole block at spawn is grass.
            continue
          if result.treeWithin(x, y, 2):
            continue
          result.setBlock(x, y, 0, bkTree)
          planted = true
          break plantAny
    if not planted:
      break

  # 2b. ...and it has to be REACHABLE without a pickaxe, or the seed is dead.
  result.openSurfaceRoute(spawn.x, spawn.y)

  # 3. The floor under spawn is always stone: the first dig_down is the
  #    cobblestone rung and never drops the cog into a cave or onto lava.
  if levels > 1:
    result.setBlock(spawn.x, spawn.y, 1, bkStone)

  # 4. Global minima per level, in this order.
  if levels > 1:
    result.promoteStone(seed, 1, bkCoalOre, config.minCoalStone)
  if levels > 2:
    result.promoteStone(seed, 2, bkIronOre, config.minIronIron)
    result.promoteStone(seed, 2, bkCoalOre, config.minCoalIron)
  if levels > 3:
    result.promoteStone(seed, 3, bkDiamondOre, config.minDiamond)
    result.promoteStone(seed, 3, bkIronOre, config.minIronDiamond)

  # 5. No lava seals a level: every level stays at least 78% diggable.
  ##  The note gives this bound twice and the two disagree: "below 700 ...
  ##  until it is 700" and "at least 78 % diggable". 78 % of the 900 interior
  ##  cells is 702, which satisfies BOTH readings, so the percentage is what
  ##  the code takes.
  let floorCells = ((size - 2) * (size - 2) * 78) div 100
  for z in 2 ..< levels:
    result.unsealLava(seed, z, floorCells)

  # The forced-stone floor under spawn survives every later pass.
  if levels > 1:
    result.setBlock(spawn.x, spawn.y, 1, bkStone)

# ---------------------------------------------------------------------------
#  Visibility
# ---------------------------------------------------------------------------

proc viewRadius*(config: GameConfig, z: int): int {.inline.} =
  if z <= 0: config.surfaceViewRadius else: config.deepViewRadius

proc observe*(world: var World, x, y, z, radius, tick: int): int =
  ## Marks the (2r+1)^2 window centred on the cog on its own level as seen and
  ## returns how many cells were newly revealed. No occlusion, no
  ## line-of-sight: the depth-dependent radius already does that work.
  for cy in max(0, y - radius) .. min(world.levelSize - 1, y + radius):
    for cx in max(0, x - radius) .. min(world.levelSize - 1, x + radius):
      let idx = world.cellIndex(cx, cy, z)
      if not world.seen[idx]:
        inc result
      world.seen[idx] = true
      world.known[idx] = world.cells[idx]
      world.seenTick[idx] = int32(tick)

proc observeCell*(world: var World, x, y, z, tick: int): int =
  ## Reveals exactly one cell (the one under a shaft, or the one above it).
  if not world.inBounds(x, y, z):
    return 0
  let idx = world.cellIndex(x, y, z)
  if not world.seen[idx]:
    result = 1
  world.seen[idx] = true
  world.known[idx] = world.cells[idx]
  world.seenTick[idx] = int32(tick)

proc cellsSeen*(world: World): int =
  for value in world.seen:
    if value:
      inc result

# ---------------------------------------------------------------------------
#  The region downsample
# ---------------------------------------------------------------------------

const RegionPriority* = [
  bkDiamondOre, bkIronOre, bkCoalOre, bkLava, bkTree, bkWater, bkTable,
  bkFurnace, bkTunnel, bkStone, bkSand, bkGrass, bkBedrock
]
  ## `D > i > c > ! > T > ~ > t > f > v > ^ > = > # > , > . > B > ?`. The two
  ## shaft glyphs are overlays rather than blocks, so they are inserted by the
  ## caller between `f` and `=`.

proc regionMap*(world: World, z, regionSize: int,
    cogX, cogY: int): seq[string] =
  ## `regionSize` strings of `regionSize` glyphs, of the CURRENT LEVEL ONLY.
  ## A region with no observed cell is `?`.
  let scale = max(1, world.levelSize div max(1, regionSize))
  result = newSeq[string](regionSize)
  for ry in 0 ..< regionSize:
    var row = newString(regionSize)
    for rx in 0 ..< regionSize:
      var
        best = -1
        anySeen = false
        hasShaftDown = false
        hasShaftUp = false
        hasCog = false
      for y in ry * scale ..< min(world.levelSize, (ry + 1) * scale):
        for x in rx * scale ..< min(world.levelSize, (rx + 1) * scale):
          if x == cogX and y == cogY:
            hasCog = true
          if not world.isSeen(x, y, z):
            continue
          anySeen = true
          if world.hasShaftDown(x, y, z):
            hasShaftDown = true
          if z > 0 and world.hasShaftDown(x, y, z - 1):
            hasShaftUp = true
          let known = world.knownAt(x, y, z)
          for i, kind in RegionPriority:
            if kind == known:
              if best < 0 or i < best:
                best = i
              break
      if hasCog:
        row[rx] = '@'
      elif not anySeen:
        row[rx] = '?'
      elif best >= 0 and best <= 7:
        row[rx] = RegionPriority[best].glyph()
      elif hasShaftDown:
        row[rx] = 'v'
      elif hasShaftUp:
        row[rx] = '^'
      elif best >= 0:
        row[rx] = RegionPriority[best].glyph()
      else:
        row[rx] = '?'
    result[ry] = row

# ---------------------------------------------------------------------------
#  4-adjacency and the goto BFS
# ---------------------------------------------------------------------------

const Neighbours* = [fcNorth, fcEast, fcSouth, fcWest]
  ## The fixed neighbour order. It is what makes the BFS path unique for a
  ## given known map, which is what makes the driver deterministic.

proc knownTraversable*(world: World, x, y, z: int): bool =
  ## A cell is traversable to the driver iff its KNOWN block is grass, sand or
  ## tunnel. `?`, water, lava, rock, ore, a table and a furnace are not - in
  ## particular the driver never routes through lava and never routes through
  ## the unknown.
  if not world.inBounds(x, y, z):
    return false
  if not world.isSeen(x, y, z):
    return false
  world.knownAt(x, y, z) in {bkGrass, bkSand, bkTunnel}

proc bfsPath*(world: World, fromX, fromY, z, toX, toY: int,
    cap: int): seq[Facing] =
  ## The `goto` path: breadth-first over known-traversable cells of ONE level,
  ## ties broken by the neighbour order above. Ends ON a traversable target,
  ## or NEXT TO a non-traversable one facing it. Yields zero steps when the
  ## target cannot be reached, which is what `macrosUnreachable` counts.
  result = @[]
  if not world.inBounds(fromX, fromY, z) or not world.inBounds(toX, toY, z):
    return
  if fromX == toX and fromY == toY:
    return
  let size = world.levelSize
  var
    prev = newSeq[int](size * size)
    prevDir = newSeq[int](size * size)
    visited = newSeq[bool](size * size)
    queue = newSeq[int](0)
  for i in 0 ..< prev.len:
    prev[i] = -1
    prevDir[i] = -1
  let start = fromY * size + fromX
  visited[start] = true
  queue.add(start)
  var head = 0
  let goal = toY * size + toX
  var reachedGoal = false
  while head < queue.len:
    let
      current = queue[head]
      cx = current mod size
      cy = current div size
    inc head
    if current == goal:
      reachedGoal = true
      break
    for dirIndex, facing in Neighbours:
      let
        nx = cx + facing.dx()
        ny = cy + facing.dy()
      if nx < 0 or ny < 0 or nx >= size or ny >= size:
        continue
      let next = ny * size + nx
      if visited[next]:
        continue
      if not world.knownTraversable(nx, ny, z):
        continue
      visited[next] = true
      prev[next] = current
      prevDir[next] = dirIndex
      queue.add(next)

  proc unwind(target: int): seq[Facing] =
    result = @[]
    var node = target
    while node != start and prev[node] >= 0:
      result.add(Neighbours[prevDir[node]])
      node = prev[node]
    reverse(result)

  if reachedGoal:
    result = unwind(goal)
  else:
    # Not traversable itself: stop on the nearest reached 4-neighbour and
    # append one turn toward it, which leaves the cog exactly positioned for
    # `mine` without moving into a cell it cannot stand in.
    var
      bestNode = -1
      bestDepth = high(int)
      bestFacing = fcNorth
    for dirIndex, facing in Neighbours:
      let
        nx = toX - facing.dx()
        ny = toY - facing.dy()
      if nx < 0 or ny < 0 or nx >= size or ny >= size:
        continue
      let node = ny * size + nx
      if not visited[node]:
        continue
      let steps = unwind(node)
      if steps.len < bestDepth:
        bestDepth = steps.len
        bestNode = node
        bestFacing = facing
    if bestNode < 0:
      return @[]
    result = unwind(bestNode)
    result.add(bestFacing)
  if result.len > cap:
    result.setLen(cap)
