## Persistent numeric plans over the native Minecraft simulator.

import std/[json, os]
import minecraft/[sim, baselines, directives, driver, llm]

const
  Variants = ["standard", "deepcut"]
  MaxSize = 32
  MaxLevels = 4
  Slots = 12
  ValueCount = 4128

var
  game: SimServer
  variant: string
  decisionId: int
  baselineState: BaselineState

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc options(width: int, start = 0): JsonNode =
  result = newJArray()
  for value in start ..< start + width:
    result.add(%value)

proc acts(): JsonNode =
  result = newJArray()
  result.add(%"none")
  for primitive in Primitive: result.add(%($primitive))
  for name in ["goto", "move", "tunnel"]: result.add(%name)

proc heads(): JsonNode =
  result = newJArray()
  for i in 0 ..< Slots:
    result.add(%*{"name": "act_" & $i, "choices": acts()})
    result.add(%*{"name": "n_" & $i, "choices": options(20, 1)})
    result.add(%*{"name": "dir_" & $i,
      "choices": ["north", "east", "south", "west"]})
    result.add(%*{"name": "x_" & $i, "choices": options(game.config.levelSize)})
    result.add(%*{"name": "y_" & $i, "choices": options(game.config.levelSize)})

proc currentDecision(): JsonNode =
  let observation = game.observationJson(game.turnsPlayed + 1,
    includeNotes = true)
  var properties = newJObject()
  var required = newJArray()
  for head in heads():
    let name = head["name"].getStr()
    properties[name] = %*{"enum": head["choices"]}
    required.add(%name)
  %*{"kind": "decision", "game": "minecraft",
    "decision_id": decisionId, "seat": 0, "engine_seat": 0,
    "turn": game.turnsPlayed + 1, "semantic_view": observation,
    "inbox": [], "messages": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": userMessage("", $observation)}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": properties,
      "required": required}, "typed_question": newJNull()}

proc encoding(): JsonNode =
  var values = newJArray()
  for name in Variants: values.add(%(if variant == name: 1 else: 0))
  values.add(%(float(game.cog.x) / float(MaxSize)))
  values.add(%(float(game.cog.y) / float(MaxSize)))
  values.add(%(float(game.cog.z) / float(MaxLevels)))
  values.add(%(float(game.gameTicksElapsed()) / float(game.config.maxTicks)))
  for facing in Facing:
    values.add(%(if game.cog.facing == facing: 1 else: 0))
  for item in Item:
    values.add(%(float(game.cog.inventory[item]) / 64.0))
  for tool in Tool:
    values.add(%(if game.cog.tools[tool]: 1 else: 0))
  for milestone in Milestone:
    values.add(%(if game.ledger.unlocked[milestone]: 1 else: 0))
  for z in 0 ..< MaxLevels:
    for y in 0 ..< MaxSize:
      for x in 0 ..< MaxSize:
        if z >= game.world.levelCount or x >= game.world.levelSize or
            y >= game.world.levelSize or not game.world.isSeen(x, y, z):
          values.add(%0)
        else:
          values.add(%(float(ord(game.world.knownAt(x, y, z)) + 1) /
            float(ord(high(Block)) + 1)))
  doAssert values.len == ValueCount
  %*{"decision_id": decisionId, "values": values,
    "action_heads": heads()}

proc reset(request: JsonNode, manifestPath: string): JsonNode =
  doAssert request["players"].getInt() == 1
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  variantConfig["seed"] = %seedOf(request["seed"].getStr())
  var config = defaultGameConfig()
  config.update($variantConfig)
  game = initSimServer(config)
  game.startGame()
  baselineState = initBaselineState()
  decisionId = 0
  currentDecision()

proc teacher(): JsonNode =
  let plan = game.baselinePlan(blMiner, DefaultBaselineParams, baselineState)
  let entries = plan.actionsJson()
  doAssert entries.len <= Slots
  var action = newJObject()
  for i in 0 ..< Slots:
    let entry = if i < entries.len: entries[i] else: newJNull()
    action["act_" & $i] = if i < entries.len: entry["act"] else: %"none"
    action["n_" & $i] = if i < entries.len and entry.hasKey("n"):
      entry["n"] else: %1
    action["dir_" & $i] = if i < entries.len and entry.hasKey("dir"):
      entry["dir"] else: %"north"
    action["x_" & $i] = if i < entries.len and entry.hasKey("x"):
      entry["x"] else: %0
    action["y_" & $i] = if i < entries.len and entry.hasKey("y"):
      entry["y"] else: %0
  %*{"response": $action}

proc step(request: JsonNode): JsonNode =
  doAssert request["decision_id"].getInt() == decisionId
  let action = parseJson(request["response"].getStr())
  for head in heads():
    let name = head["name"].getStr()
    doAssert action[name] in head["choices"], "action is masked: " & name
  var entries = newJArray()
  for i in 0 ..< Slots:
    if action["act_" & $i].getStr() == "none": continue
    entries.add(%*{
      "act": action["act_" & $i],
      "n": action["n_" & $i],
      "dir": action["dir_" & $i],
      "x": action["x_" & $i],
      "y": action["y_" & $i]
    })
  let plan = parsePlan(%*{"actions": entries}, game.config.maxActionsPerTurn,
    game.config.levelSize)
  let expanded = game.expandPlan(plan)
  game.lastPlan.truncated = expanded.truncated or plan.truncatedActions
  game.lastPlan.dropped = plan.dropped + plan.repaired
  game.lastPlan.unreachable = expanded.unreachable
  game.actionsDropped += plan.dropped
  game.repliesRepaired += plan.repaired
  game.macrosUnreachable += expanded.unreachable
  for tick in 0 ..< game.config.turnTicks:
    if game.phase == GameOver: break
    let primitive = if tick < expanded.queue.len:
      expanded.queue[tick] else: pNoop
    game.lastPlan.executed.add($primitive)
    game.step(primitive)
    if game.interruptRequested: break
  game.noteTurnEnd()
  inc decisionId
  let observation = if game.phase == GameOver:
    doAssert game.endReason == ReasonComplete, game.stopDetail
    let score = min(1.0, float(game.ledger.episodeScore(
      game.config.maxTicks)) / 2_048_000.0)
    %*{"kind": "terminal", "scores": {"0": score},
      "utilities": {"0": 2.0 * score - 1.0}}
  else:
    game.lastPlan = LastPlan(interrupted: "", notes: game.lastPlan.notes)
    currentDecision()
  %*{"kind": "accepted", "action": action,
    "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: minecraft-train-bridge MANIFEST VARIANT", 1)
  let manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in Variants
  for line in stdin.lines:
    let request = parseJson(line)
    let response = case request["kind"].getStr()
      of "reset": reset(request, manifestPath)
      of "encode": encoding()
      of "teacher": teacher()
      of "step": step(request)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
