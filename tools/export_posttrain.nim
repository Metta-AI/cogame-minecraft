## Export complete native Minecraft games as hosted plan conversations.

import std/[json, os, osproc, strutils]
import minecraft/[sim, baselines, directives, driver, llm]

when isMainModule:
  let args = commandLineParams()
  if args.len != 3:
    quit("usage: minecraft-posttrain OUTPUT EPISODES VARIANT", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  if episodes < 10: quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    var game = initSimServer(config)
    game.startGame()
    var state = initBaselineState()
    let baseline = if seed mod 2 == 0: blMiner else: blScrounger
    var rows: seq[string]
    for turnIndex in 1 .. config.maxTurns:
      if game.phase == GameOver: break
      game.lastPlan = LastPlan(interrupted: "", notes: game.lastPlan.notes)
      let observation = game.observationJson(turnIndex, includeNotes = true)
      let teacher = game.baselinePlan(baseline, DefaultBaselineParams, state)
      let completion = %*{"actions": teacher.actionsJson(),
        "say": teacher.say, "notes": teacher.notes}
      let accepted = parsePlan(completion, config.maxActionsPerTurn,
        config.levelSize)
      doAssert accepted.dropped == 0 and accepted.repaired == 0
      doAssert accepted.actionsJson() == teacher.actionsJson()
      rows.add($(%*{
        "episode_id": "minecraft-" & variant & "-" & $seed,
        "seed": "minecraft-" & variant & "-" & $seed,
        "decision_id": rows.len,
        "prompt": [
          {"role": "system", "content": SystemPrompt},
          {"role": "user", "content": userMessage("", $observation)}
        ],
        "completion": [{"role": "assistant", "content": $completion}],
        "game": "minecraft", "action_schema_revision": "minecraft-plan-v1"
      }))
      let expanded = game.expandPlan(accepted)
      game.lastPlan.truncated = expanded.truncated
      game.lastPlan.unreachable = expanded.unreachable
      if accepted.notes.len > 0: game.lastPlan.notes = accepted.notes
      for tick in 0 ..< config.turnTicks:
        if game.phase == GameOver: break
        let primitive = if tick < expanded.queue.len:
          expanded.queue[tick] else: pNoop
        game.lastPlan.executed.add($primitive)
        game.step(primitive)
        if game.interruptRequested: break
      game.noteTurnEnd()
    doAssert game.phase == GameOver and game.endReason == ReasonComplete,
      "seed " & $seed & " ended " & game.endReason & "/" & game.endRule
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    let results = parseJson(game.runResultsJson())
    runs.add(%*{"seed": seed, "ticks": game.tickCount,
      "decisions": rows.len, "scores": results["scores"],
      "reason": results["reason"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "minecraft", "variant": variant,
    "source_revision": revision, "teacher": "miner-and-scrounger",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
