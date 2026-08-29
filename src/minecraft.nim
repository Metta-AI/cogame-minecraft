import
  std/[json, os, sysrand],
  bitworld/runtime,
  minecraft/sim,
  minecraft/server

const LegacyFixedSeed = 0xA6019
  ## The compiled-in default seed, which doubles as the "nobody chose a seed"
  ## sentinel: a config carrying it (or no seed at all) gets a fresh random
  ## one. With a public fixed seed the whole world - every ore, every lava
  ## pocket, the exact route to the diamond - would be pre-computable.

proc seedPinned(configJson: string): bool =
  ## True when the runtime config explicitly pins a seed other than the
  ## sentinel (fixture recordings, A/B batteries, forensic re-runs).
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed") and
      node["seed"].getInt != LegacyFixedSeed
  except CatchableError:
    false

proc randomSeed(): int =
  ## A crypto-random 31-bit seed from the OS.
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(MinecraftError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc stripUnpinnedSeed(configJson: string): string =
  if configJson.len == 0:
    return configJson
  try:
    let node = parseJson(configJson)
    if node.kind == JObject and node.hasKey("seed"):
      node.delete("seed")
    $node
  except CatchableError:
    configJson

when isMainModule:
  let
    runtimeConfig = readRuntimeConfig()
    localReplayPath =
      if runtimeConfig.replayUri.len > 0:
        getTempDir() / ("minecraft-replay-" & $getCurrentProcessId() &
          ".replay")
      else:
        ""

  var config = defaultGameConfig()
  if seedPinned(runtimeConfig.config):
    config.update(runtimeConfig.config)
  else:
    ## Randomise BEFORE parsing: `config.update` is where everything
    ## seed-derived resolves, so the randomised seed must already be in place
    ## or every process would generate the same world.
    config.seed = randomSeed()
    config.update(stripUnpinnedSeed(runtimeConfig.config))
    echo "seed not pinned; randomized"

  echo "minecraft config: host=", runtimeConfig.host,
    " port=", runtimeConfig.port,
    " seed=", config.seed,
    " variant=", config.variantText(),
    " num_agents=", config.numAgents,
    " levels=", config.levelCount, "x", config.levelSize, "x",
    config.levelSize,
    " maxTurns=", config.maxTurns,
    " maxTicks=", config.maxTicks,
    " par=", config.parMilestones

  let loadReplayPath =
    if runtimeConfig.replayMode:
      let path = getTempDir() / ("minecraft-load-replay-" &
        $getCurrentProcessId() & ".replay")
      writeFile(path, runtimeConfig.replay)
      path
    else:
      ""

  runServerLoop(
    runtimeConfig.host,
    runtimeConfig.port,
    config,
    localReplayPath,
    loadReplayPath,
    "",
    runtimeConfig
  )
