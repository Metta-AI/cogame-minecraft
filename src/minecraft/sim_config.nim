## `GameConfig` lifecycle: defaults, `update` from the runner's config JSON,
## the validators, and the replay's config JSON.
##
## Forked from `src/ctf/sim_config.nim`. The validators at that file's
## `:688-713` are KEPT and are why every number in the design note's cadence
## table is what it is: `attempt1Ms` and `retryMs` must be whole seconds
## (curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is whole
## seconds, so anything else is silently floored), their sum must fit inside
## `turnBudgetMs`, and `wallClockBudgetSeconds` must be positive.

import std/[json, strutils]

import sim_types

const
  DefaultLevelCount* = 4
  DefaultLevelSize* = 32
  DefaultTurnTicks* = 20
  DefaultMaxTurns* = 48
  DefaultMaxTicks* = 960

proc defaultGameConfig*(): GameConfig =
  result.seed = 0xA6019
  result.numAgents = 1
  result.minPlayers = 1
  result.variant = "standard"

  result.levelCount = DefaultLevelCount
  result.levelSize = DefaultLevelSize
  result.surfaceViewRadius = 5
  result.deepViewRadius = 2
  result.regionSize = 16

  result.turnTicks = DefaultTurnTicks
  result.maxTurns = DefaultMaxTurns
  result.maxTicks = DefaultMaxTicks

  result.veinThreshold = 600
  result.caveThresholdStone = 880
  result.caveThresholdIron = 850
  result.caveThresholdDiamond = 830
  result.lavaChanceIron = 12
  result.lavaChanceDiamond = 30
  result.coalChanceStone = 180
  result.coalChanceIron = 80
  result.ironChanceIron = 140
  result.ironChanceDiamond = 110
  result.diamondChance = 70
  result.minCoalStone = 12
  result.minIronIron = 14
  result.minCoalIron = 6
  result.minDiamond = 8
  result.minIronDiamond = 6

  result.parMilestones = 6
  result.maxActionsPerTurn = 12
  result.macroPrimitiveCap = 20

  result.attempt1Ms = 6000
  result.retryMs = 3000
  result.turnBudgetMs = 9500
  result.turnSpacingMs = 2600
  result.wallClockBudgetSeconds = 660
  result.lobbyJoinTimeoutTicks = 2400
  result.startWaitTicks = 24
  result.gameOverTicks = 96

  result.fastMode = true
  result.showPlayerLabels = false
  result.model = ""
  result.maxOutputTokens = 900
  result.speed = 1
  result.slots = @[]

proc readInt(node: JsonNode, key: string, target: var int) =
  if node.hasKey(key) and node[key].kind == JInt:
    target = node[key].getInt()

proc readBool(node: JsonNode, key: string, target: var bool) =
  if node.hasKey(key) and node[key].kind == JBool:
    target = node[key].getBool()

proc readString(node: JsonNode, key: string, target: var string) =
  if node.hasKey(key) and node[key].kind == JString:
    target = node[key].getStr()

proc validate*(config: GameConfig) =
  if config.levelCount < 1 or config.levelCount > 8:
    raise newException(MinecraftError,
      "Config field levelCount must be 1..8.")
  if config.levelSize < 8 or config.levelSize > 64:
    raise newException(MinecraftError,
      "Config field levelSize must be 8..64.")
  if config.regionSize < 1 or config.regionSize > config.levelSize:
    raise newException(MinecraftError,
      "Config field regionSize must be 1..levelSize.")
  if config.surfaceViewRadius < 1 or config.deepViewRadius < 1:
    raise newException(MinecraftError,
      "Config view radii must be positive.")
  if config.turnTicks < 1:
    raise newException(MinecraftError,
      "Config field turnTicks must be at least 1.")
  if config.maxTurns < 1:
    raise newException(MinecraftError,
      "Config field maxTurns must be at least 1.")
  if config.maxTicks != config.maxTurns * config.turnTicks:
    raise newException(MinecraftError,
      "Config field maxTicks must equal maxTurns * turnTicks.")
  if config.maxTicks >= 1000:
    ## The scoring dominance bound: speedBonus must never reach one rung's
    ## worth, or it would stop being a pure tie-break.
    raise newException(MinecraftError,
      "Config field maxTicks must be below 1000 so speedBonus stays a " &
      "tie-break.")
  if config.parMilestones < 0 or config.parMilestones > ord(high(Milestone)) + 1:
    raise newException(MinecraftError,
      "Config field parMilestones must be 0..11.")
  if config.maxActionsPerTurn < 1 or config.maxActionsPerTurn > 64:
    raise newException(MinecraftError,
      "Config field maxActionsPerTurn must be 1..64.")
  if config.macroPrimitiveCap < 1:
    raise newException(MinecraftError,
      "Config field macroPrimitiveCap must be at least 1.")
  if config.veinThreshold < 0 or config.veinThreshold > 1023:
    raise newException(MinecraftError,
      "Config field veinThreshold must be 0..1023.")
  if config.turnBudgetMs < 1 or config.attempt1Ms < 1 or config.retryMs < 1:
    raise newException(MinecraftError,
      "Config LLM deadline fields must be positive.")
  if config.attempt1Ms + config.retryMs > config.turnBudgetMs:
    raise newException(MinecraftError,
      "Config fields attempt1Ms + retryMs must fit inside turnBudgetMs.")
  if config.attempt1Ms mod 1000 != 0 or config.retryMs mod 1000 != 0:
    raise newException(MinecraftError,
      "Config fields attempt1Ms and retryMs must be whole seconds " &
      "(multiples of 1000): curly's transport timeout has whole-second " &
      "granularity, so anything else is silently floored.")
  if config.turnSpacingMs < 0:
    raise newException(MinecraftError,
      "Config field turnSpacingMs must not be negative.")
  if config.wallClockBudgetSeconds < 1:
    raise newException(MinecraftError,
      "Config field wallClockBudgetSeconds must be positive.")
  if config.numAgents < 0 or config.numAgents > 1:
    raise newException(MinecraftError,
      "Config field num_agents must be 0 or 1: this is a single-seat game.")
  if config.slots.len > MaxPlayers:
    raise newException(MinecraftError,
      "Config field players cannot have more than 8 entries.")

proc readSlots(node: JsonNode, config: var GameConfig) =
  ## `players[]` carries the seat's REAL name; `tokens[]` is injected by the
  ## runner and never appears in a shipped `game_config`.
  if node.hasKey("players") and node["players"].kind == JArray:
    var slots: seq[PlayerSlotConfig] = @[]
    for entry in node["players"]:
      var slot = PlayerSlotConfig()
      if entry.kind == JObject:
        if entry.hasKey("name") and entry["name"].kind == JString:
          slot.name = entry["name"].getStr()
      elif entry.kind == JString:
        slot.name = entry.getStr()
      slots.add(slot)
    config.slots = slots
  if node.hasKey("tokens") and node["tokens"].kind == JArray:
    var index = 0
    for entry in node["tokens"]:
      while config.slots.len <= index:
        config.slots.add(PlayerSlotConfig())
      if entry.kind == JString:
        config.slots[index].token = entry.getStr()
      inc index

proc update*(config: var GameConfig, jsonText: string) =
  ## Updates a gameplay config from a JSON object.
  if jsonText.len == 0:
    return
  var node: JsonNode
  try:
    node = parseJson(jsonText)
  except CatchableError as error:
    raise newException(MinecraftError,
      "Could not parse config JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(MinecraftError, "Config must be a JSON object.")

  node.readInt("seed", config.seed)
  node.readInt("num_agents", config.numAgents)
  node.readInt("numAgents", config.numAgents)
  node.readInt("minPlayers", config.minPlayers)
  node.readString("variant", config.variant)

  node.readInt("levelCount", config.levelCount)
  node.readInt("levelSize", config.levelSize)
  node.readInt("surfaceViewRadius", config.surfaceViewRadius)
  node.readInt("deepViewRadius", config.deepViewRadius)
  node.readInt("regionSize", config.regionSize)

  node.readInt("turnTicks", config.turnTicks)
  node.readInt("maxTurns", config.maxTurns)
  node.readInt("maxTicks", config.maxTicks)

  node.readInt("veinThreshold", config.veinThreshold)
  node.readInt("caveThresholdStone", config.caveThresholdStone)
  node.readInt("caveThresholdIron", config.caveThresholdIron)
  node.readInt("caveThresholdDiamond", config.caveThresholdDiamond)
  node.readInt("lavaChanceIron", config.lavaChanceIron)
  node.readInt("lavaChanceDiamond", config.lavaChanceDiamond)
  node.readInt("coalChanceStone", config.coalChanceStone)
  node.readInt("coalChanceIron", config.coalChanceIron)
  node.readInt("ironChanceIron", config.ironChanceIron)
  node.readInt("ironChanceDiamond", config.ironChanceDiamond)
  node.readInt("diamondChance", config.diamondChance)
  node.readInt("minCoalStone", config.minCoalStone)
  node.readInt("minIronIron", config.minIronIron)
  node.readInt("minCoalIron", config.minCoalIron)
  node.readInt("minDiamond", config.minDiamond)
  node.readInt("minIronDiamond", config.minIronDiamond)

  node.readInt("parMilestones", config.parMilestones)
  node.readInt("maxActionsPerTurn", config.maxActionsPerTurn)
  node.readInt("macroPrimitiveCap", config.macroPrimitiveCap)

  node.readInt("attempt1Ms", config.attempt1Ms)
  node.readInt("retryMs", config.retryMs)
  node.readInt("turnBudgetMs", config.turnBudgetMs)
  node.readInt("turnSpacingMs", config.turnSpacingMs)
  node.readInt("wallClockBudgetSeconds", config.wallClockBudgetSeconds)
  node.readInt("lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
  node.readInt("startWaitTicks", config.startWaitTicks)
  node.readInt("gameOverTicks", config.gameOverTicks)

  node.readBool("fastMode", config.fastMode)
  node.readBool("showPlayerLabels", config.showPlayerLabels)
  node.readString("model", config.model)
  node.readInt("maxOutputTokens", config.maxOutputTokens)
  node.readInt("speed", config.speed)

  node.readSlots(config)
  config.validate()

proc configJson*(config: GameConfig): string =
  ## The complete replay config: seed, variant, every rule constant, the
  ## seat's real name and its token. The wasm viewer regenerates all four
  ## levels from this and the seed alone, with no fetch.
  var
    players = newJArray()
    tokens = newJArray()
  for slot in config.slots:
    players.add(%*{"name": slot.name})
    tokens.add(%slot.token)
  let node = %*{
    "seed": config.seed,
    "num_agents": config.numAgents,
    "minPlayers": config.minPlayers,
    "variant": config.variant,
    "levelCount": config.levelCount,
    "levelSize": config.levelSize,
    "surfaceViewRadius": config.surfaceViewRadius,
    "deepViewRadius": config.deepViewRadius,
    "regionSize": config.regionSize,
    "turnTicks": config.turnTicks,
    "maxTurns": config.maxTurns,
    "maxTicks": config.maxTicks,
    "veinThreshold": config.veinThreshold,
    "caveThresholdStone": config.caveThresholdStone,
    "caveThresholdIron": config.caveThresholdIron,
    "caveThresholdDiamond": config.caveThresholdDiamond,
    "lavaChanceIron": config.lavaChanceIron,
    "lavaChanceDiamond": config.lavaChanceDiamond,
    "coalChanceStone": config.coalChanceStone,
    "coalChanceIron": config.coalChanceIron,
    "ironChanceIron": config.ironChanceIron,
    "ironChanceDiamond": config.ironChanceDiamond,
    "diamondChance": config.diamondChance,
    "minCoalStone": config.minCoalStone,
    "minIronIron": config.minIronIron,
    "minCoalIron": config.minCoalIron,
    "minDiamond": config.minDiamond,
    "minIronDiamond": config.minIronDiamond,
    "parMilestones": config.parMilestones,
    "maxActionsPerTurn": config.maxActionsPerTurn,
    "macroPrimitiveCap": config.macroPrimitiveCap,
    "attempt1Ms": config.attempt1Ms,
    "retryMs": config.retryMs,
    "turnBudgetMs": config.turnBudgetMs,
    "turnSpacingMs": config.turnSpacingMs,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "startWaitTicks": config.startWaitTicks,
    "gameOverTicks": config.gameOverTicks,
    "fastMode": config.fastMode,
    "showPlayerLabels": config.showPlayerLabels,
    "maxOutputTokens": config.maxOutputTokens,
    "speed": config.speed,
    "players": players,
    "slots": tokens
  }
  $node

proc configuredPlayerName*(config: GameConfig, requestedSlot: int,
    token: string): string =
  ## The real player name for a seat, resolved by slot or by token.
  if requestedSlot >= 0 and requestedSlot < config.slots.len:
    return config.slots[requestedSlot].name
  if token.len > 0:
    for slot in config.slots:
      if slot.token.len > 0 and slot.token == token:
        return slot.name
  ""

proc hasConfiguredTokens*(config: GameConfig): bool =
  for slot in config.slots:
    if slot.token.len > 0:
      return true
  false

proc hasConfiguredToken*(config: GameConfig, token: string): bool =
  for slot in config.slots:
    if slot.token.len > 0 and slot.token == token:
      return true
  false

proc slotForToken*(config: GameConfig, token: string): int =
  result = -1
  for i, slot in config.slots:
    if slot.token.len > 0 and slot.token == token:
      return i

proc seatCountOf*(config: GameConfig): int =
  max(1, config.numAgents)

proc variantText*(config: GameConfig): string =
  if config.variant.len > 0: config.variant.strip() else: "standard"
