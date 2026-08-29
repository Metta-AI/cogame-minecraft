## Shared types and constants for cogame-minecraft.
##
## Forked from `coworld-ctf`'s `src/ctf/sim_types.nim`: the module keeps that
## file's role (the single place every other module reads a constant from), its
## `GameVersion` prepend-only changelog discipline, `TargetFps`, the websocket
## route names and the RUNE caps — and replaces paintbot's arena/gun/paint
## types with the four-level blocky world this game is about.
##
## RUNE DISCIPLINE. Every cap below is measured in RUNES (Unicode codepoints),
## never bytes. `directives.truncateRunes` is the only place a recorded string
## is shortened. A byte-truncated multi-byte character renders fine in a
## browser and then fails a strict UTF-8 parser, which is exactly the class of
## bug that makes a replay unreadable to everything but the one lenient viewer.

import std/[strutils, unicode]

const
  GameVersion* = "3"
    ## Changelog, PREPEND ONLY (the starter's discipline):
    ##   3 - no dead seeds: post-pass 2b opens a tier-0 route from spawn to a
    ##       tree, so a water-ringed spawn can no longer score zero for every
    ##       policy (35 of 300 standard seeds were sealed like that).
    ##   2 - lava is a live hazard: the generator's cave gate for lava rises
    ##       from 120 to 300, so lava exists on 98% of seeds instead of 32%.
    ##   1 - first release: the eleven-rung ObtainDiamond ladder over four
    ##       stacked 32x32 levels, seventeen primitives and three macros.
  GameName* = "minecraft"

  TargetFps* = 24
    ## Wall-clock frames per second for the live serve loop. Also the replay
    ## timebase (ReplayFps) so a recorded time converts back to a tick.
  ReplayFps* = TargetFps

  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]

  WebSocketPath* = "/player"
  GlobalWebSocketPath* = "/global"
  ReplayWebSocketPath* = "/replay"

  MaxPlayers* = 8
    ## Protocol ceiling on slots. This game seats exactly one.

  MaxSayRunes* = 160
    ## RE-PINNED in this fork. The starter's `MaxSayRunes` is `ShoutMaxChars`
    ## (10) - a ten-character in-world shout. A cog narrating a descent needs
    ## a sentence, and the shout mechanic is deleted here, so the cap is the
    ## feed line's cap instead.
  MaxNoteRunes* = 400
    ## RE-PINNED (starter: 160). The private scratchpad carries the z,x,y of
    ## every ore the cog has seen across four levels between turns.
  MaxPromptRunes* = 4000
  MaxPolicyLabelRunes* = 64
  MaxFallbackDetailRunes* = 200
  MaxReplyBytes* = 4096
    ## Bytes read from the provider before parsing.

type
  MinecraftError* = object of CatchableError
  SimGuardError* = object of MinecraftError

  GamePhase* = enum
    Lobby, Playing, GameOver

  Block* = enum
    ## The closed block enum. Exactly one block per cell, always.
    bkGrass = "grass"
    bkSand = "sand"
    bkWater = "water"
    bkTree = "oak tree"
    bkStone = "stone"
    bkCoalOre = "coal ore"
    bkIronOre = "iron ore"
    bkDiamondOre = "diamond ore"
    bkTunnel = "tunnel"
    bkLava = "lava"
    bkBedrock = "bedrock"
    bkTable = "crafting table"
    bkFurnace = "furnace"

  Facing* = enum
    ## World frame: north = -y, south = +y, east = +x, west = -x.
    fcNorth = "north"
    fcEast = "east"
    fcSouth = "south"
    fcWest = "west"

  Item* = enum
    itLog = "log"
    itPlanks = "planks"
    itStick = "stick"
    itCobblestone = "cobblestone"
    itCoal = "coal"
    itRawIron = "raw_iron"
    itIronIngot = "iron_ingot"
    itDiamond = "diamond"

  Tool* = enum
    tlWooden = "wooden_pickaxe"
    tlStone = "stone_pickaxe"
    tlIron = "iron_pickaxe"

  Primitive* = enum
    ## The seventeen primitives, by name. Nothing else is a primitive.
    pNoop = "noop"
    pMoveNorth = "move_north"
    pMoveEast = "move_east"
    pMoveSouth = "move_south"
    pMoveWest = "move_west"
    pMine = "mine"
    pDigDown = "dig_down"
    pClimbUp = "climb_up"
    pPlaceBlock = "place_block"
    pPlaceTable = "place_crafting_table"
    pPlaceFurnace = "place_furnace"
    pCraftPlanks = "craft_planks"
    pCraftSticks = "craft_sticks"
    pCraftWoodenPickaxe = "craft_wooden_pickaxe"
    pCraftStonePickaxe = "craft_stone_pickaxe"
    pCraftIronPickaxe = "craft_iron_pickaxe"
    pSmeltIron = "smelt_iron"

  Milestone* = enum
    ## The eleven rungs of the ObtainDiamond ladder, in canonical order.
    ## Rung `i` is worth `2^i`, so one rung higher beats every combination of
    ## the rungs below it - an integer identity, not a convention.
    msLog = "log"
    msPlanks = "planks"
    msCraftingTable = "crafting_table"
    msWoodenPickaxe = "wooden_pickaxe"
    msCobblestone = "cobblestone"
    msStonePickaxe = "stone_pickaxe"
    msIronOre = "iron_ore"
    msFurnace = "furnace"
    msIronIngot = "iron_ingot"
    msIronPickaxe = "iron_pickaxe"
    msDiamond = "diamond"

  PlayerSlotConfig* = object
    name*: string
    token*: string

  GameConfig* = object
    ## Every rule constant the sim reads. The replay carries all of them, so
    ## the wasm viewer regenerates the whole world from the bytes it has.
    seed*: int
    numAgents*: int
    minPlayers*: int
    variant*: string

    levelCount*: int
    levelSize*: int
    surfaceViewRadius*: int
    deepViewRadius*: int
    regionSize*: int

    turnTicks*: int
    maxTurns*: int
    maxTicks*: int

    veinThreshold*: int
    caveThresholdStone*: int
    caveThresholdIron*: int
    caveThresholdDiamond*: int
    lavaChanceIron*: int
    lavaChanceDiamond*: int
    coalChanceStone*: int
    coalChanceIron*: int
    ironChanceIron*: int
    ironChanceDiamond*: int
    diamondChance*: int
    minCoalStone*: int
    minIronIron*: int
    minCoalIron*: int
    minDiamond*: int
    minIronDiamond*: int

    parMilestones*: int
    maxActionsPerTurn*: int
    macroPrimitiveCap*: int

    attempt1Ms*: int
    retryMs*: int
    turnBudgetMs*: int
    turnSpacingMs*: int
    wallClockBudgetSeconds*: int
    lobbyJoinTimeoutTicks*: int
    startWaitTicks*: int
    gameOverTicks*: int

    fastMode*: bool
    showPlayerLabels*: bool
    model*: string
    maxOutputTokens*: int
    speed*: int

    slots*: seq[PlayerSlotConfig]

const
  ## `results.endRule` - a closed enum.
  EndRuleDiamond* = "diamond"
  EndRuleDeath* = "death"
  EndRuleTurnCap* = "turnCap"
  EndRuleTickCap* = "tickCap"
  EndRuleWallClock* = "wallClock"
  EndRuleFault* = "fault"

  ## `results.reason` - the platform's closed enum. Exactly three are legal.
  ReasonComplete* = "complete"
  ReasonDeadline* = "deadline"
  ReasonFault* = "fault"

  DeathCauseLava* = "lava"
  DeathCauseNone* = "none"

  IdentityNames* = [
    "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"
  ]
    ## The starter's identity vocabulary (`src/ctf/roster.nim:64-65`), kept.
    ## Only the in-game alias ever reaches an observation or the board; the
    ## real policy name lives spectator-side.

proc seatAlias*(slot: int): string =
  ## The in-game alias for a seat: `Alpha` for the only seat this game has.
  if slot < 0 or slot >= IdentityNames.len:
    return "Cog" & $slot
  let name = IdentityNames[slot]
  name[0..0].toUpperAscii() & name[1 .. ^1]

proc glyph*(b: Block): char =
  ## The one glyph the seat and the viewer both read for a block.
  case b
  of bkGrass: '.'
  of bkSand: ','
  of bkWater: '~'
  of bkTree: 'T'
  of bkStone: '#'
  of bkCoalOre: 'c'
  of bkIronOre: 'i'
  of bkDiamondOre: 'D'
  of bkTunnel: '='
  of bkLava: '!'
  of bkBedrock: 'B'
  of bkTable: 't'
  of bkFurnace: 'f'

proc walkable*(b: Block): bool =
  ## Lava IS walkable - stepping into it is how the cog dies.
  b in {bkGrass, bkSand, bkTunnel, bkLava}

proc mineTier*(b: Block): int =
  ## The lowest pickaxe tier that can mine this block, or -1 for "never".
  case b
  of bkTree: 0
  of bkStone, bkCoalOre: 1
  of bkIronOre: 2
  of bkDiamondOre: 3
  else: -1

proc dropOf*(b: Block): tuple[has: bool, item: Item, count: int] =
  ## What mining this block yields.
  case b
  of bkTree: (true, itLog, 3)
  of bkStone: (true, itCobblestone, 1)
  of bkCoalOre: (true, itCoal, 1)
  of bkIronOre: (true, itRawIron, 1)
  of bkDiamondOre: (true, itDiamond, 1)
  else: (false, itLog, 0)

proc becomes*(b: Block): Block =
  ## What a mined block leaves behind.
  case b
  of bkTree: bkGrass
  of bkStone, bkCoalOre, bkIronOre, bkDiamondOre: bkTunnel
  else: b

proc milestonePoints*(m: Milestone): int =
  ## Rung `i` is worth `2^i`.
  1 shl ord(m)

proc levelLabel*(z: int): string =
  ## The y-label the seat and the spectator both read for a level.
  case z
  of 0: "y=64 (surface)"
  of 1: "y=48 (stone)"
  of 2: "y=32 (iron depth)"
  of 3: "y=12 (diamond depth)"
  else: "y=? (level " & $z & ")"

proc levelShortLabel*(z: int): string =
  case z
  of 0: "y=64"
  of 1: "y=48"
  of 2: "y=32"
  of 3: "y=12"
  else: "y=?"

proc dx*(f: Facing): int =
  case f
  of fcEast: 1
  of fcWest: -1
  else: 0

proc dy*(f: Facing): int =
  case f
  of fcSouth: 1
  of fcNorth: -1
  else: 0

proc moveOf*(f: Facing): Primitive =
  case f
  of fcNorth: pMoveNorth
  of fcEast: pMoveEast
  of fcSouth: pMoveSouth
  of fcWest: pMoveWest

proc facingOfMove*(p: Primitive): tuple[ok: bool, facing: Facing] =
  case p
  of pMoveNorth: (true, fcNorth)
  of pMoveEast: (true, fcEast)
  of pMoveSouth: (true, fcSouth)
  of pMoveWest: (true, fcWest)
  else: (false, fcNorth)

proc parseFacing*(text: string): tuple[ok: bool, facing: Facing] =
  ## Tolerant, case-insensitive, with the aliases the reply schema names.
  case text.strip().toLowerAscii()
  of "north", "n", "up": (true, fcNorth)
  of "east", "e", "right": (true, fcEast)
  of "south", "s", "down": (true, fcSouth)
  of "west", "w", "left": (true, fcWest)
  else: (false, fcNorth)

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc truncateBytes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` BYTES, still on a RUNE boundary: the cap
  ## that is a size bound rather than a length bound (`MaxReplyBytes`, the
  ## provider's reply) is a byte cap by definition, and 4096 runes of 4-byte
  ## codepoints is 16 KiB, not 4 KiB. Never splits a codepoint, so item 9's
  ## rune discipline still holds.
  if limit <= 0:
    return ""
  if text.len <= limit:
    return text
  var cut = limit
  while cut > 0 and (text[cut].uint8 and 0b1100_0000'u8) == 0b1000_0000'u8:
    dec cut
  text[0 ..< cut]

const Mix64Mask* = 0x3FFF_FFFF
  ## 30 bits. `mix64` is read as an `int`, and the sim compiles BOTH natively
  ## (64-bit int) and to wasm32 (32-BIT int). Masking to 63 bits produced a
  ## value that fits a native int and traps `value out of range` on the very
  ## first world generation in the browser - with the whole bundle loaded,
  ## every asset 200, and the viewer stuck on the loading curtain
  ## (run 33241005565). Thirty bits is unambiguously positive in an int32 and
  ## is what makes the native and wasm worlds bit-identical by construction.

proc mix64u*(a, b, c, d: int): uint64 =
  ## splitmix64 over the four mixed words. A pure HASH, not a stream: nothing
  ## the policy does can shift a draw, reorder draws, or consume one out from
  ## under a later tick, so the world of seed `s` is the same world however
  ## the cog plays it. `uint64` is 64 bits on every target Nim supports,
  ## including wasm32, so the mixing itself is portable.
  var x = uint64(a) * 0x9E3779B97F4A7C15'u64
  x = x xor (uint64(b) * 0xBF58476D1CE4E5B9'u64)
  x = x xor (uint64(c) * 0x94D049BB133111EB'u64)
  x = x xor (uint64(d) * 0xD6E8FEB86659FD93'u64)
  x = x xor (x shr 30)
  x = x * 0xBF58476D1CE4E5B9'u64
  x = x xor (x shr 27)
  x = x * 0x94D049BB133111EB'u64
  x = x xor (x shr 31)
  x

proc mix64*(a, b, c, d: int): int =
  ## The generator's draw: `mix64u` narrowed to 30 bits so it fits an `int` on
  ## a 32-bit target. EVERY generated quantity in this game is a read of this.
  int(mix64u(a, b, c, d) and uint64(Mix64Mask))

proc mixHash*(state: uint64, value: int): uint64 =
  ## One step of the rolling game hash.
  var x = state xor uint64(value and 0x7FFF_FFFF)
  x = x * 0x100000001B3'u64
  x = x xor (x shr 29)
  x
