## The `miner` parameter sweep.
##
## Like the starter's `tools/tune_baselines.nim`, the baseline's tunables are
## CHOSEN, not guessed: this sweeps them over a fixed seed battery of both
## variants, scores each candidate by the total `milestoneScore` it reaches,
## and writes the winner to `tools/ci/baseline_tuning.json`.
## `tests/test_minecraft_driver.nim` then asserts the shipped
## `DefaultBaselineParams` still equal that file, and `ci.yml` re-runs the
## sweep with `--check` so a drift is a red build rather than a silent
## regression.
##
##   nim r --path:src tools/tune_baselines.nim           # sweep and write
##   nim r --path:src tools/tune_baselines.nim --check   # sweep and compare

import std/[json, os, strformat, strutils]

import minecraft/sim
import minecraft/driver
import minecraft/baselines

const SweepSeeds = 40

proc variantConfig(seed: int, deep: bool): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  if deep:
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

proc playOut(config: GameConfig, params: BaselineParams): SimServer =
  result = initSimServer(config)
  result.startGame()
  var
    state = initBaselineState()
    queue: seq[Primitive] = @[]
    turnTicks = 0
    fresh = true
  while result.phase == Playing:
    if fresh or turnTicks >= result.config.turnTicks:
      let plan = baselinePlan(result, blMiner, params, state)
      queue = expandPlan(result, plan).queue
      turnTicks = 0
      fresh = false
      result.noteTurnEnd()
      if result.phase != Playing:
        break
    var primitive = pNoop
    if queue.len > 0:
      primitive = queue[0]
      queue.delete(0)
    result.step(primitive)
    inc turnTicks
    if result.interruptRequested:
      queue.setLen(0)
      turnTicks = result.config.turnTicks

proc score(params: BaselineParams): tuple[total, rung9: int] =
  for seed in 1 .. SweepSeeds:
    for deep in [false, true]:
      let sim = playOut(variantConfig(seed * 7 + 1, deep), params)
      result.total += sim.ledger.milestoneScore()
      if not deep and sim.ledger.milestonesReached() >= 9:
        inc result.rung9

proc toJson(params: BaselineParams, total, rung9: int): JsonNode =
  %*{
    "_comment": "The pick tools/tune_baselines.nim's sweep produced. " &
      "tests/test_minecraft_driver.nim asserts the shipped " &
      "DefaultBaselineParams still equal it; ci.yml re-runs the sweep with " &
      "--check.",
    "objective": "total milestoneScore of the miner baseline over " &
      $SweepSeeds & " standard + " & $SweepSeeds & " deepcut seeds",
    "score": total,
    "rung9_of_standard_seeds": rung9,
    "woodPlanks": params.woodPlanks,
    "woodSticks": params.woodSticks,
    "stoneCobble": params.stoneCobble,
    "stoneCoal": params.stoneCoal,
    "sweepLength": params.sweepLength,
    "sweepTurns": params.sweepTurns,
    "latticeSpacing": params.latticeSpacing,
    "valueFirst": params.valueFirst
  }

when isMainModule:
  var
    best = DefaultBaselineParams
    bestScore = -1
    bestRung9 = 0
    evaluated = 0
  for woodPlanks in [8, 12, 16]:
    for woodSticks in [4, 6, 8]:
      for stoneCobble in [12, 16, 20]:
        for sweepLength in [6, 9]:
          for latticeSpacing in [2, 3]:
            for valueFirst in [true, false]:
              var candidate = DefaultBaselineParams
              candidate.woodPlanks = woodPlanks
              candidate.woodSticks = woodSticks
              candidate.stoneCobble = stoneCobble
              candidate.sweepLength = sweepLength
              candidate.latticeSpacing = latticeSpacing
              candidate.valueFirst = valueFirst
              let got = candidate.score()
              inc evaluated
              if got.total > bestScore:
                bestScore = got.total
                bestRung9 = got.rung9
                best = candidate
  echo &"swept {evaluated} candidates; best score {bestScore}, " &
    &"rung 9 on {bestRung9}/{SweepSeeds} standard seeds"
  let payload = best.toJson(bestScore, bestRung9)
  let path = "tools/ci/baseline_tuning.json"
  if paramCount() >= 1 and paramStr(1) == "--check":
    let pinned = parseJson(readFile(path))
    for key in ["woodPlanks", "woodSticks", "stoneCobble", "stoneCoal",
        "sweepLength", "sweepTurns", "latticeSpacing"]:
      if pinned{key}.getInt != payload{key}.getInt:
        quit("sweep drifted on " & key & ": pinned " & $pinned{key} &
          ", swept " & $payload{key}, 1)
    if pinned{"valueFirst"}.getBool != payload{"valueFirst"}.getBool:
      quit("sweep drifted on valueFirst", 1)
    echo "ok: the pinned tuning is still the swept pick"
  else:
    writeFile(path, payload.pretty() & "\n")
    echo "wrote ", path
