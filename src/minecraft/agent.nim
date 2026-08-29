## The cog and the seventeen primitives.
##
## Nothing else mutates the world. Every primitive costs its tick whether or
## not it applies: an inapplicable primitive is a no-op that still spends the
## tick, and against a hard deadline that is the game's entire difficulty.

import sim_types, world

type
  Cog* = object
    x*, y*, z*: int
    facing*: Facing
    inventory*: array[Item, int]
    tools*: array[Tool, bool]
    alive*: bool

  BlockedWhy* = enum
    bwNone = ""
    bwNoTier = "no_tier"
    bwUnmineable = "unmineable"
    bwBedrockFloor = "bedrock_floor"
    bwLavaBelow = "lava_below"
    bwNoShaft = "no_shaft"
    bwNoMaterials = "no_materials"
    bwNoTable = "no_table"
    bwNoFurnace = "no_furnace"
    bwBadTarget = "bad_target"
    bwBlockedMove = "blocked_move"

  ActOutcome* = object
    ## What one primitive did, for the tick loop's bookkeeping and the feed.
    blocked*: bool
    why*: BlockedWhy
    mined*: bool
    minedBlock*: Block
    minedX*, minedY*, minedZ*: int
    placed*: bool
    placedBlock*: Block
    placedOver*: Block
    placedX*, placedY*, placedZ*: int
    shaftSet*: bool
    shaftX*, shaftY*, shaftZ*: int
    crafted*: bool
    craftedItem*: Item
    craftedCount*: int
    smelted*: bool
    descended*: bool
    ascended*: bool
    bridged*: bool
    steppedIntoLava*: bool
    brokeOntoLava*: bool
    lavaX*, lavaY*, lavaZ*: int
    moved*: bool

const StackCap* = 64
  ## A Minecraft stack. A collection that would exceed it is capped and still
  ## unlocks its milestone.

proc initCog*(spawn: Cell): Cog =
  result.x = spawn.x
  result.y = spawn.y
  result.z = spawn.z
  result.facing = fcSouth
  result.alive = true
  for item in Item:
    result.inventory[item] = 0
  for tool in Tool:
    result.tools[tool] = false

proc tier*(cog: Cog): int =
  ## 3 if iron else 2 if stone else 1 if wooden else 0.
  if cog.tools[tlIron]: 3
  elif cog.tools[tlStone]: 2
  elif cog.tools[tlWooden]: 1
  else: 0

proc give(cog: var Cog, item: Item, count: int) =
  cog.inventory[item] = min(StackCap, cog.inventory[item] + count)

proc take(cog: var Cog, item: Item, count: int): bool =
  if cog.inventory[item] < count:
    return false
  cog.inventory[item] -= count
  true

proc aheadCell*(cog: Cog): Cell =
  Cell(x: cog.x + cog.facing.dx(), y: cog.y + cog.facing.dy(), z: cog.z)

proc adjacentHas*(w: World, cog: Cog, kind: Block): bool =
  ## Chebyshev distance 1, ON THE SAME LEVEL - the recipes' `near.table` and
  ## `near.furnace`.
  for dy in -1 .. 1:
    for dx in -1 .. 1:
      if w.at(cog.x + dx, cog.y + dy, cog.z) == kind:
        return true
  false

proc doMove(w: var World, cog: var Cog, facing: Facing,
    outcome: var ActOutcome) =
  ## Sets `facing` AND steps one cell if that cell is walkable; if it is not,
  ## the cog only TURNS. A blocked move is a turn, not a no-op - the semantics
  ## an implementer guesses wrong.
  cog.facing = facing
  let
    nx = cog.x + facing.dx()
    ny = cog.y + facing.dy()
  let target = w.at(nx, ny, cog.z)
  if not target.walkable():
    outcome.blocked = true
    outcome.why = bwBlockedMove
    return
  cog.x = nx
  cog.y = ny
  outcome.moved = true
  if target == bkLava:
    cog.alive = false
    outcome.steppedIntoLava = true
    outcome.lavaX = nx
    outcome.lavaY = ny
    outcome.lavaZ = cog.z

proc doMine(w: var World, cog: var Cog, outcome: var ActOutcome) =
  let
    ahead = cog.aheadCell()
    target = w.at(ahead.x, ahead.y, ahead.z)
    blockTier = target.mineTier()
  if blockTier < 0:
    outcome.blocked = true
    outcome.why = bwUnmineable
    return
  if cog.tier() < blockTier:
    outcome.blocked = true
    outcome.why = bwNoTier
    return
  let drop = target.dropOf()
  if drop.has:
    cog.give(drop.item, drop.count)
  w.setBlock(ahead.x, ahead.y, ahead.z, target.becomes())
  outcome.mined = true
  outcome.minedBlock = target
  outcome.minedX = ahead.x
  outcome.minedY = ahead.y
  outcome.minedZ = ahead.z

proc doDigDown(w: var World, cog: var Cog, tick: int,
    outcome: var ActOutcome) =
  ## The six numbered cases. Digging down ONTO lava is survivable; walking into
  ## lava you can see is not - the seat cannot look through the floor, so a
  ## blind descent must never be an instant loss.
  if cog.z >= w.levelCount - 1:
    outcome.blocked = true
    outcome.why = bwBedrockFloor
    return
  if w.hasShaftDown(cog.x, cog.y, cog.z):
    cog.z += 1
    outcome.descended = true
    return
  let below = w.at(cog.x, cog.y, cog.z + 1)
  if below == bkLava:
    discard w.observeCell(cog.x, cog.y, cog.z + 1, tick)
    outcome.blocked = true
    outcome.why = bwLavaBelow
    outcome.brokeOntoLava = true
    outcome.lavaX = cog.x
    outcome.lavaY = cog.y
    outcome.lavaZ = cog.z + 1
    return
  let blockTier = below.mineTier()
  if below == bkBedrock or blockTier < 0:
    outcome.blocked = true
    outcome.why = bwUnmineable
    return
  if cog.tier() < blockTier:
    outcome.blocked = true
    outcome.why = bwNoTier
    return
  let drop = below.dropOf()
  if drop.has:
    cog.give(drop.item, drop.count)
  w.setBlock(cog.x, cog.y, cog.z + 1, bkTunnel)
  w.setShaftDown(cog.x, cog.y, cog.z, true)
  outcome.shaftSet = true
  outcome.shaftX = cog.x
  outcome.shaftY = cog.y
  outcome.shaftZ = cog.z
  outcome.mined = true
  outcome.minedBlock = below
  outcome.minedX = cog.x
  outcome.minedY = cog.y
  outcome.minedZ = cog.z + 1
  cog.z += 1
  outcome.descended = true

proc doClimbUp(w: World, cog: var Cog, outcome: var ActOutcome) =
  if cog.z <= 0 or not w.hasShaftDown(cog.x, cog.y, cog.z - 1):
    outcome.blocked = true
    outcome.why = bwNoShaft
    return
  cog.z -= 1
  outcome.ascended = true

proc doPlaceBlock(w: var World, cog: var Cog, outcome: var ActOutcome) =
  ## Costs 1 cobblestone and turns the faced cell into stone if it is lava or
  ## water. This is how you bridge, and the only way to un-kill a lava cell.
  let ahead = cog.aheadCell()
  let target = w.at(ahead.x, ahead.y, ahead.z)
  if target notin {bkLava, bkWater}:
    outcome.blocked = true
    outcome.why = bwBadTarget
    return
  if not cog.take(itCobblestone, 1):
    outcome.blocked = true
    outcome.why = bwNoMaterials
    return
  w.setBlock(ahead.x, ahead.y, ahead.z, bkStone)
  outcome.placed = true
  outcome.placedBlock = bkStone
  outcome.placedOver = target
  outcome.placedX = ahead.x
  outcome.placedY = ahead.y
  outcome.placedZ = ahead.z
  outcome.bridged = true

proc doPlaceStructure(w: var World, cog: var Cog, kind: Block,
    outcome: var ActOutcome) =
  let
    ahead = cog.aheadCell()
    target = w.at(ahead.x, ahead.y, ahead.z)
    cost = if kind == bkTable: 4 else: 8
    item = if kind == bkTable: itPlanks else: itCobblestone
  if target notin {bkGrass, bkSand, bkTunnel}:
    outcome.blocked = true
    outcome.why = bwBadTarget
    return
  if not cog.take(item, cost):
    outcome.blocked = true
    outcome.why = bwNoMaterials
    return
  w.setBlock(ahead.x, ahead.y, ahead.z, kind)
  outcome.placed = true
  outcome.placedBlock = kind
  outcome.placedOver = target
  outcome.placedX = ahead.x
  outcome.placedY = ahead.y
  outcome.placedZ = ahead.z

proc doCraftPickaxe(w: World, cog: var Cog, tool: Tool,
    outcome: var ActOutcome) =
  if cog.tools[tool]:
    return                     ## crafting an owned pickaxe is a free no-op
  if not w.adjacentHas(cog, bkTable):
    outcome.blocked = true
    outcome.why = bwNoTable
    return
  let
    item = case tool
      of tlWooden: itPlanks
      of tlStone: itCobblestone
      of tlIron: itIronIngot
  if cog.inventory[item] < 3 or cog.inventory[itStick] < 2:
    outcome.blocked = true
    outcome.why = bwNoMaterials
    return
  discard cog.take(item, 3)
  discard cog.take(itStick, 2)
  cog.tools[tool] = true
  outcome.crafted = true
  outcome.craftedCount = 1

proc doSmelt(w: World, cog: var Cog, outcome: var ActOutcome) =
  if not w.adjacentHas(cog, bkFurnace):
    outcome.blocked = true
    outcome.why = bwNoFurnace
    return
  if cog.inventory[itRawIron] < 1 or cog.inventory[itCoal] < 1:
    outcome.blocked = true
    outcome.why = bwNoMaterials
    return
  discard cog.take(itRawIron, 1)
  discard cog.take(itCoal, 1)
  cog.give(itIronIngot, 1)
  outcome.smelted = true

proc applyPrimitive*(w: var World, cog: var Cog, primitive: Primitive,
    tick: int): ActOutcome =
  ## One primitive, one tick, exactly as the design's action table specifies.
  result.why = bwNone
  case primitive
  of pNoop:
    discard
  of pMoveNorth, pMoveEast, pMoveSouth, pMoveWest:
    let facing = primitive.facingOfMove()
    w.doMove(cog, facing.facing, result)
  of pMine:
    w.doMine(cog, result)
  of pDigDown:
    w.doDigDown(cog, tick, result)
  of pClimbUp:
    w.doClimbUp(cog, result)
  of pPlaceBlock:
    w.doPlaceBlock(cog, result)
  of pPlaceTable:
    w.doPlaceStructure(cog, bkTable, result)
  of pPlaceFurnace:
    w.doPlaceStructure(cog, bkFurnace, result)
  of pCraftPlanks:
    if cog.take(itLog, 1):
      cog.give(itPlanks, 4)
      result.crafted = true
      result.craftedItem = itPlanks
      result.craftedCount = 4
    else:
      result.blocked = true
      result.why = bwNoMaterials
  of pCraftSticks:
    if cog.take(itPlanks, 2):
      cog.give(itStick, 4)
      result.crafted = true
      result.craftedItem = itStick
      result.craftedCount = 4
    else:
      result.blocked = true
      result.why = bwNoMaterials
  of pCraftWoodenPickaxe:
    w.doCraftPickaxe(cog, tlWooden, result)
  of pCraftStonePickaxe:
    w.doCraftPickaxe(cog, tlStone, result)
  of pCraftIronPickaxe:
    w.doCraftPickaxe(cog, tlIron, result)
  of pSmeltIron:
    w.doSmelt(cog, result)
