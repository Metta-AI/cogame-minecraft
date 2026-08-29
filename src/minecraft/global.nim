## The board: the sprite-protocol emitter.
##
## Forked from `src/ctf/global.nim`, which is 8 000 lines of pixel arena,
## raycast fog and paint FX. Three named edits, exactly as the design note
## specifies:
##
## 1. The board is ONE 32x32 CELL GRID AT A TIME, not a pixel arena. The
##    raycast fov cache and shadowcasting are deleted and replaced by the
##    window's boolean mask plus the per-level known-map mask, which the
##    viewer draws as the two-level fog wash. The board's native size is
##    32 x 24 = 768 x 768 px, one 24 px tile per cell, and the viewer draws
##    the level the cog is currently on.
## 2. Block, overlay and workshop pools: `BlockBase` (a tile layer per level,
##    redrawn INCREMENTALLY on mutation, never per-frame from scratch),
##    `ShaftOverlay` and the cog, emitted incrementally like the starter's
##    other object families.
## 3. Baked block bed: the tiles are loaded once from `data/art/` (the
##    nano-banana renders, split by `tools/art/split_sheets.py`) and scaled to
##    the cell size at startup with pixie, exactly the way the starter bakes
##    endzone paint - so the per-frame cost is the cog, the shaft overlays,
##    the fog masks and the chrome, never 1024 tile decodes.

import std/[json, os, strutils, tables]

import bitworld/spriteprotocol
import pixie

import sim, broadcast

const
  BroadcastChromeSpriteId* = 4090
    ## The reserved 1x1 never-drawn sprite whose LABEL carries the broadcast
    ## chrome JSON. The starter's trick, kept: the chrome rides the SAME
    ## binary channel the board rides, which is the only channel that survives
    ## a hosted replay.

  CellPixels* = 24
  BoardLayerId* = 0
  BoardLayerType* = 0

  TileSpriteBase = 100      ## 100 + ord(Block)
  ShaftDownSpriteId = 140
  ShaftUpSpriteId = 141
  FogUnseenSpriteId = 150
  FogDimSpriteId = 151
  CogSpriteBase = 160       ## 160 + ord(Facing)

  BlockObjectBase = 1000
  ShaftObjectBase = 5000
  FogObjectBase = 10000
  CogObjectId = 20000

  BlockZ = 0
  ShaftZ = 10
  CogZ = 20
  FogZ = 30

type
  GlobalViewerState* = object
    ## Per-viewer diff state. Only what CHANGED is emitted, so the steady
    ## frame is the cog plus a handful of tiles.
    initialized*: bool
    spritesSent*: bool
    level*: int
    tiles*: seq[int]
    shafts*: seq[int]
    fog*: seq[int]
    cogSprite*: int
    cogX*, cogY*: int
    leadSent*: bool
    mouseX*, mouseY*, mouseLayer*: int
    mouseDown*: bool
    clickPending*: bool
    replayCommands*: seq[char]
    replaySeekTick*: int

proc initGlobalViewerState*(): GlobalViewerState =
  result.level = -1
  result.cogSprite = -1
  result.cogX = -1
  result.cogY = -1
  result.replaySeekTick = -1
  result.mouseLayer = BoardLayerId

proc applyGlobalViewerMessage*(state: var GlobalViewerState,
    message: string) =
  ## Applies one or more global protocol client messages. Whole-string
  ## commands (`s:<tick>`) are intercepted before the legacy char-by-char
  ## transport path, so a multi-digit tick is never mangled into speed
  ## keystrokes.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientMouseMoveMessage:
      state.mouseX = item.x
      state.mouseY = item.y
      state.mouseLayer = if item.hasLayer: item.layer else: BoardLayerId
    of SpriteClientMouseButtonMessage:
      if item.button == 0x01'u8:
        state.mouseDown = item.down
        if state.mouseDown:
          state.clickPending = true
    of SpriteClientChatMessage:
      if item.text.startsWith("s:"):
        let tick = try: parseInt(item.text[2 .. ^1]) except ValueError: -1
        if tick >= 0:
          state.replaySeekTick = tick
      elif item.text.startsWith("v:"):
        discard              ## one seat: there is no POV to select
      else:
        for ch in item.text:
          state.replayCommands.add(ch)
    else:
      discard

# ---------------------------------------------------------------------------
#  The baked tile bed
# ---------------------------------------------------------------------------

type BakedTile = object
  pixels: seq[uint8]

var
  tileCache: Table[int, BakedTile]
  tilesBaked = false

proc artDir(): string =
  ## The art ships beside the binary in the image and is preloaded into the
  ## wasm module's virtual FS as `data/`, so one relative path covers both.
  for candidate in ["data/art", "../data/art", "/workspace/minecraft/data/art"]:
    if dirExists(candidate):
      return candidate
  "data/art"

proc solidTile(r, g, b: uint8): BakedTile =
  result.pixels = newSeq[uint8](CellPixels * CellPixels * 4)
  for i in 0 ..< CellPixels * CellPixels:
    result.pixels[i * 4] = r
    result.pixels[i * 4 + 1] = g
    result.pixels[i * 4 + 2] = b
    result.pixels[i * 4 + 3] = 255

proc washTile(alpha: uint8): BakedTile =
  result.pixels = newSeq[uint8](CellPixels * CellPixels * 4)
  for i in 0 ..< CellPixels * CellPixels:
    result.pixels[i * 4 + 3] = alpha

proc loadArtTile(name: string, size: int, fallback: BakedTile): BakedTile =
  let path = artDir() / (name & ".png")
  if not fileExists(path):
    return fallback
  try:
    let scaled = readImage(path).resize(size, size)
    result.pixels = newSeq[uint8](size * size * 4)
    for i, pixel in scaled.data:
      let straight = pixel.rgba()
      result.pixels[i * 4] = straight.r
      result.pixels[i * 4 + 1] = straight.g
      result.pixels[i * 4 + 2] = straight.b
      result.pixels[i * 4 + 3] = straight.a
  except CatchableError:
    return fallback

proc tileFileName(b: Block): string =
  case b
  of bkGrass: "tile_grass"
  of bkSand: "tile_sand"
  of bkWater: "tile_water"
  of bkTree: "tile_tree"
  of bkStone: "tile_stone"
  of bkCoalOre: "tile_coal_ore"
  of bkIronOre: "tile_iron_ore"
  of bkDiamondOre: "tile_diamond_ore"
  of bkTunnel: "tile_tunnel"
  of bkLava: "tile_lava"
  of bkBedrock: "tile_bedrock"
  of bkTable: "tile_table"
  of bkFurnace: "tile_furnace"

proc fallbackColor(b: Block): tuple[r, g, b: uint8] =
  case b
  of bkGrass: (74'u8, 124'u8, 62'u8)
  of bkSand: (214'u8, 191'u8, 133'u8)
  of bkWater: (52'u8, 96'u8, 168'u8)
  of bkTree: (36'u8, 82'u8, 40'u8)
  of bkStone: (128'u8, 128'u8, 132'u8)
  of bkCoalOre: (72'u8, 72'u8, 76'u8)
  of bkIronOre: (176'u8, 108'u8, 66'u8)
  of bkDiamondOre: (86'u8, 208'u8, 214'u8)
  of bkTunnel: (46'u8, 44'u8, 44'u8)
  of bkLava: (226'u8, 106'u8, 30'u8)
  of bkBedrock: (26'u8, 26'u8, 28'u8)
  of bkTable: (140'u8, 96'u8, 52'u8)
  of bkFurnace: (110'u8, 110'u8, 114'u8)

proc bakeTiles() =
  if tilesBaked:
    return
  tilesBaked = true
  for b in Block:
    let color = fallbackColor(b)
    tileCache[TileSpriteBase + ord(b)] = loadArtTile(tileFileName(b),
      CellPixels, solidTile(color.r, color.g, color.b))
  tileCache[ShaftDownSpriteId] = loadArtTile("tile_shaft_down", CellPixels,
    solidTile(12, 12, 12))
  tileCache[ShaftUpSpriteId] = loadArtTile("tile_shaft_up", CellPixels,
    solidTile(210, 210, 190))
  for facing in Facing:
    let name = "cog_" & $facing
    tileCache[CogSpriteBase + ord(facing)] = loadArtTile(name, CellPixels,
      solidTile(224, 72, 56))
  tileCache[FogUnseenSpriteId] = washTile(255)
  tileCache[FogDimSpriteId] = washTile(110)

proc tilePixels(spriteId: int): seq[uint8] =
  bakeTiles()
  if tileCache.hasKey(spriteId):
    return tileCache[spriteId].pixels
  solidTile(255, 0, 255).pixels

proc warmBoardRenderCaches*(sim: SimServer) =
  ## Bakes the tile bed BEFORE the listener opens: a viewer's first-message
  ## clock starts at its successful connect, so nothing may be accepted until
  ## every frame the loop will ever build can be assembled instantly.
  bakeTiles()

# ---------------------------------------------------------------------------
#  Frames
# ---------------------------------------------------------------------------

proc tileSpriteFor(sim: SimServer, x, y, z: int): int =
  TileSpriteBase + ord(sim.world.at(x, y, z))

proc fogSpriteFor(sim: SimServer, x, y, z: int): int =
  ## The two-level fog wash: unseen is black, seen-and-left-behind is dim, the
  ## live window is clear.
  let radius = viewRadius(sim.config, sim.cog.z)
  if z == sim.cog.z and abs(x - sim.cog.x) <= radius and
      abs(y - sim.cog.y) <= radius:
    return -1
  if sim.world.isSeen(x, y, z):
    return FogDimSpriteId
  FogUnseenSpriteId

proc addSpriteDefs(packet: var seq[uint8]) =
  bakeTiles()
  for b in Block:
    let id = TileSpriteBase + ord(b)
    packet.addSprite(id, CellPixels, CellPixels, tilePixels(id),
      "tile:" & $b)
  packet.addSprite(ShaftDownSpriteId, CellPixels, CellPixels,
    tilePixels(ShaftDownSpriteId), "shaft:down")
  packet.addSprite(ShaftUpSpriteId, CellPixels, CellPixels,
    tilePixels(ShaftUpSpriteId), "shaft:up")
  for facing in Facing:
    let id = CogSpriteBase + ord(facing)
    packet.addSprite(id, CellPixels, CellPixels, tilePixels(id),
      "cog:" & $facing)
  packet.addSprite(FogUnseenSpriteId, CellPixels, CellPixels,
    tilePixels(FogUnseenSpriteId), "fog:unseen")
  packet.addSprite(FogDimSpriteId, CellPixels, CellPixels,
    tilePixels(FogDimSpriteId), "fog:dim")

proc buildBoardPacket*(sim: SimServer, state: GlobalViewerState,
    nextState: var GlobalViewerState): seq[uint8] =
  ## One board frame, as a DIFF against the viewer's last frame.
  let
    size = sim.world.levelSize
    cells = size * size
  nextState = state
  result = @[]

  if not nextState.initialized:
    nextState.initialized = true
    nextState.tiles = newSeq[int](cells)
    nextState.shafts = newSeq[int](cells)
    nextState.fog = newSeq[int](cells)
    for i in 0 ..< cells:
      nextState.tiles[i] = -1
      nextState.shafts[i] = -1
      nextState.fog[i] = -1
    result.addLayer(BoardLayerId, BoardLayerType, SpriteLayerZoomableFlag)
    result.addViewport(BoardLayerId, size * CellPixels, size * CellPixels)

  if not nextState.spritesSent:
    nextState.spritesSent = true
    result.addSpriteDefs()

  let z = sim.cog.z
  let levelChanged = nextState.level != z
  nextState.level = z

  for y in 0 ..< size:
    for x in 0 ..< size:
      let idx = y * size + x
      let tile = sim.tileSpriteFor(x, y, z)
      if levelChanged or nextState.tiles[idx] != tile:
        nextState.tiles[idx] = tile
        result.addObject(BlockObjectBase + idx, x * CellPixels,
          y * CellPixels, BlockZ, BoardLayerId, tile)

      var shaft = -1
      if sim.world.hasShaftDown(x, y, z):
        shaft = ShaftDownSpriteId
      elif z > 0 and sim.world.hasShaftDown(x, y, z - 1):
        shaft = ShaftUpSpriteId
      if levelChanged or nextState.shafts[idx] != shaft:
        if nextState.shafts[idx] >= 0 and shaft < 0:
          result.addDeleteObject(ShaftObjectBase + idx)
        elif shaft >= 0:
          result.addObject(ShaftObjectBase + idx, x * CellPixels,
            y * CellPixels, ShaftZ, BoardLayerId, shaft)
        nextState.shafts[idx] = shaft

      let fog = sim.fogSpriteFor(x, y, z)
      if levelChanged or nextState.fog[idx] != fog:
        if nextState.fog[idx] >= 0 and fog < 0:
          result.addDeleteObject(FogObjectBase + idx)
        elif fog >= 0:
          result.addObject(FogObjectBase + idx, x * CellPixels,
            y * CellPixels, FogZ, BoardLayerId, fog)
        nextState.fog[idx] = fog

  let cogSprite = CogSpriteBase + ord(sim.cog.facing)
  if sim.cog.alive:
    if nextState.cogSprite != cogSprite or nextState.cogX != sim.cog.x or
        nextState.cogY != sim.cog.y or levelChanged:
      nextState.cogSprite = cogSprite
      nextState.cogX = sim.cog.x
      nextState.cogY = sim.cog.y
      result.addObject(CogObjectId, sim.cog.x * CellPixels,
        sim.cog.y * CellPixels, CogZ, BoardLayerId, cogSprite)
  elif nextState.cogSprite >= 0:
    nextState.cogSprite = -1
    result.addDeleteObject(CogObjectId)

proc addChromeSprite*(packet: var seq[uint8], json: string) =
  ## The chrome JSON rides as the LABEL of a reserved never-drawn 1x1 sprite.
  packet.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0], json)

proc buildSpriteProtocolUpdates*(sim: var SimServer,
    state: GlobalViewerState, nextState: var GlobalViewerState,
    events: JsonNode, playing: bool, speed, maxTick: int,
    looping, transportEnabled: bool, mismatchTick: int): seq[uint8] =
  ## The live-serve frame: board diff plus the chrome sprite.
  result = sim.buildBoardPacket(state, nextState)
  result.addChromeSprite(sim.buildStateJson(events, playing, speed, maxTick,
    looping, transportEnabled, mismatchTick))

proc chunkSpritePacket*(packet: seq[uint8], maxBytes: int): seq[seq[uint8]] =
  ## Ships in WS-frame-sized chunks AT MESSAGE BOUNDARIES: the hosted replay
  ## viewer closes any frame over 1 MiB (1009 "message too big"), and the
  ## client accumulates sprite/object state across binary messages, so N
  ## chunks are equivalent to one packet.
  result = @[]
  if packet.len == 0:
    return
  var
    start = 0
    offset = 0
  while offset < packet.len:
    let size = spriteMessageBytes(packet, offset)
    if size <= 0:
      break
    if offset > start and offset - start + size > maxBytes:
      result.add(packet[start ..< offset])
      start = offset
    offset += size
  if start < packet.len:
    result.add(packet[start ..< packet.len])
