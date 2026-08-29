## Manifest pins.
##
## Design note §Tests item 36. Item 37 ("the manifest loads under the installed
## CLI") is a CI step in `coworld-release.yml`'s build/certify pair rather than
## a Nim test: the `coworld` CLI is a Python package the sandbox and this test
## job do not have.

import std/[json, os, strutils]

import minecraft/sim
import minecraft/driver
import minecraft/baselines

let manifest = parseJson(readFile("coworld_manifest_template.json"))

block topLevel:
  doAssert manifest.hasKey("$schema")
  doAssert manifest["tags"].len >= 3
  doAssert manifest.hasKey("episode_timeout_minutes"),
    "episode_timeout_minutes lives at the TOP level, not under game"
  doAssert not manifest["game"].hasKey("tags"), "game.tags must not exist"
  doAssert not manifest.hasKey("version"), "no top-level version"
  doAssert not manifest["game"].hasKey("display_name")
  echo "ok: the top-level shape"

block gameBlock:
  let game = manifest["game"]
  doAssert game["name"].getStr == "minecraft",
    "game.name must equal the slug so the secret namespace agrees"
  doAssert game["replay_viewer"]["bundle"].getStr == "static-replay-viewer"
  doAssert game.hasKey("description") and game["description"].getStr.len > 0
  doAssert game["owner"].getStr.len > 0
  doAssert game["runnable"]["type"].getStr == "game"
  doAssert game["runnable"]["run"][0].getStr == "/bin/minecraft"
  doAssert game["runnable"]["image"].getStr == "{{MINECRAFT_IMAGE}}"
  doAssert game["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr ==
    "secret://coworld/minecraft/anthropic_api_key"
  for key in ["player", "global"]:
    doAssert game["protocols"].hasKey(key),
      "game.protocols carries BOTH player and global"
    doAssert game["protocols"][key].kind == JObject,
      "a protocol is an OBJECT, never a bare string"
    doAssert game["protocols"][key]["type"].getStr == "uri"
    doAssert game["protocols"][key]["value"].getStr.len > 0
  doAssert game["docs"]["readme"]["type"].getStr == "uri"
  doAssert game["docs"]["pages"].len >= 4
  for page in game["docs"]["pages"]:
    doAssert page.hasKey("id") and page.hasKey("title")
    doAssert page["content"]["type"].getStr == "uri"
  echo "ok: the game block"

block configSchema:
  let schema = manifest["game"]["config_schema"]
  doAssert schema["additionalProperties"].getBool == false
  doAssert "tokens" in schema["required"].to(seq[string])
  doAssert "players" in schema["required"].to(seq[string])
  for key, prop in schema["properties"]:
    if prop{"type"}.getStr == "array":
      doAssert prop.hasKey("minItems"), key & " has no minItems"
      doAssert prop.hasKey("maxItems"), key & " has no maxItems"
  doAssert schema["properties"]["num_agents"]["minimum"].getInt == 1
  doAssert schema["properties"]["num_agents"]["maximum"].getInt == 1
  echo "ok: the config schema"

block resultsSchema:
  let schema = manifest["game"]["results_schema"]
  doAssert schema["additionalProperties"].getBool == false
  let props = schema["properties"]
  doAssert props["reason"]["enum"].to(seq[string]) ==
    @["complete", "deadline", "fault"]
  doAssert props["endRule"]["enum"].to(seq[string]) ==
    @["diamond", "death", "turnCap", "tickCap", "wallClock", "fault"]
  doAssert props["deathCause"]["enum"].to(seq[string]) == @["lava", "none"]
  for key in ["milestoneIds", "milestonePoints", "milestoneUnlocked",
      "milestoneTick"]:
    doAssert props[key]["minItems"].getInt == 11
    doAssert props[key]["maxItems"].getInt == 11
  doAssert props["ticksPerLevel"]["minItems"].getInt == 4
  doAssert props["ticksPerLevel"]["maxItems"].getInt == 4
  doAssert props["toolsOwned"]["minItems"].getInt == 0
  doAssert props["toolsOwned"]["maxItems"].getInt == 3
  echo "ok: the results schema"

block declaredPlayers:
  doAssert manifest["player"].len == 1,
    "num_agents = 1 leaves exactly ONE certification slot, and every " &
    "declared player must occupy one"
  let player = manifest["player"][0]
  doAssert player["id"].getStr == "miner"
  doAssert player["run"][0].getStr == "/bin/minecraft-player"
  let cpu = player["resources"]["limits"]["cpu"].getStr
  doAssert cpu == "1" or parseFloat(cpu) >= 1.0,
    "player[].resources.limits.cpu must be at least 1"
  doAssert manifest["certification"]["players"][0]["player_id"].getStr ==
    player["id"].getStr
  echo "ok: exactly one declared player, and it is seated"

proc assertGameConfig(node: JsonNode, label: string) =
  doAssert node["num_agents"].getInt == 1, label & ": num_agents"
  doAssert node["players"].len == 1, label & ": players"
  doAssert not node.hasKey("tokens"),
    label & ": no game_config may carry runner-managed tokens"
  doAssert node["maxTicks"].getInt ==
    node["maxTurns"].getInt * node["turnTicks"].getInt, label & ": maxTicks"
  doAssert node["maxTicks"].getInt < 1000,
    label & ": maxTicks must stay below the scoring dominance bound"
  doAssert node["wallClockBudgetSeconds"].getInt <= 660,
    label & ": wallClockBudgetSeconds"
  doAssert node["attempt1Ms"].getInt mod 1000 == 0, label & ": attempt1Ms"
  doAssert node["retryMs"].getInt mod 1000 == 0, label & ": retryMs"
  doAssert node["attempt1Ms"].getInt + node["retryMs"].getInt <=
    node["turnBudgetMs"].getInt, label & ": the deadlines must fit"

block variantsAndFixture:
  var configs: seq[(string, JsonNode)] = @[]
  for variant in manifest["variants"]:
    doAssert not variant.hasKey("num_agents"),
      "num_agents lives inside game_config, never at a variant's top level"
    doAssert variant["description"].getStr.len > 200
    configs.add((variant["id"].getStr, variant["game_config"]))
  configs.add(("certification", manifest["certification"]["game_config"]))
  doAssert configs.len == 3, "two variants and the certification fixture"
  doAssert manifest["certification"]["players"].len ==
    manifest["certification"]["game_config"]["players"].len
  doAssert manifest["certification"]["players"].len == 1
  for (label, node) in configs:
    assertGameConfig(node, label)
    # ...and every one of them actually CONSTRUCTS a valid GameConfig,
    # generates its four levels and produces the turn schedule the note
    # claims (the collab-cooking 0.1.1 scar: test EVERY variant, not just the
    # fixture).
    var config = defaultGameConfig()
    var payload = copy(node)
    payload["tokens"] = %*["token-0"]
    config.update($payload)
    var sim = initSimServer(config)
    sim.startGame()
    doAssert sim.world.levelCount == 4
    doAssert sim.world.levelSize == 32
    doAssert sim.config.maxTicks == sim.config.maxTurns * sim.config.turnTicks
    let spawn = sim.world.spawnCell()
    doAssert sim.world.at(spawn.x, spawn.y, 0) == bkGrass
    doAssert sim.world.at(spawn.x, spawn.y, 1) == bkStone
    # a full scripted run of the variant terminates inside its own caps
    var state = initBaselineState()
    var queue: seq[Primitive] = @[]
    var turnTicks = config.turnTicks
    while sim.phase == Playing:
      if turnTicks >= config.turnTicks:
        queue = expandPlan(sim,
          baselinePlan(sim, blMiner, DefaultBaselineParams, state)).queue
        turnTicks = 0
        sim.noteTurnEnd()
        if sim.phase != Playing:
          break
      var primitive = pNoop
      if queue.len > 0:
        primitive = queue[0]
        queue.delete(0)
      sim.step(primitive)
      inc turnTicks
      if sim.interruptRequested:
        queue.setLen(0)
        turnTicks = config.turnTicks
    doAssert sim.gameTicksElapsed() <= config.maxTicks, label
    doAssert sim.turnsPlayed <= config.maxTurns, label
    doAssert sim.reasonText() == ReasonComplete, label
  echo "ok: both variants and the certification fixture construct and play"

block secretNamespaceAgrees:
  let uri = manifest["game"]["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr
  doAssert uri == "secret://coworld/" & manifest["game"]["name"].getStr &
    "/anthropic_api_key"
  doAssert manifest["game"]["name"].getStr == GameName
  echo "ok: the secret namespace, the slug and game.name all agree"

block composeAgrees:
  let compose = readFile("compose.yaml")
  doAssert "minecraft:" in compose, "the compose SERVICE name is the slug"
  doAssert "image: coworld-minecraft:latest" in compose
  doAssert "platform: linux/amd64" in compose
  doAssert "network: host" in compose
  # {{MINECRAFT_IMAGE}} is derived from the compose service name
  doAssert manifest["game"]["runnable"]["image"].getStr == "{{MINECRAFT_IMAGE}}"
  echo "ok: compose.yaml and the manifest image placeholder agree"

block policiesJson:
  let policies = parseJson(readFile("tools/ci/policies.json"))
  doAssert policies.len == 4
  var prompts = 0
  var scripted = 0
  var owned = 0
  for policy in policies:
    doAssert policy["run"].getStr == "/bin/minecraft-player"
    doAssert policy["name"].getStr.startsWith("minecraft-")
    if policy["env"].hasKey("PLAYER_PROMPT"):
      inc prompts
      doAssert policy["env"]["PLAYER_PROMPT"].getStr.len > 200
    if policy["env"].hasKey("PLAYER_SCRIPTED"):
      inc scripted
      doAssert policy["env"]["PLAYER_SCRIPTED"].getStr in ["miner", "scrounger"]
    if policy.hasKey("player"):
      inc owned
      doAssert policy["player"].getStr ==
        "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
      doAssert policy["env"].hasKey("PLAYER_PROMPT"),
        "a scripted policy seated as a champion is a FAILURE state"
  doAssert prompts == 2, "two LLM champions"
  doAssert scripted == 2, "two scripted fillers"
  doAssert owned == 1, "champion #2 is uploaded as daveey-1"
  echo "ok: policies.json is two champions and two fillers, one image"

echo "test_minecraft_manifest: PASS"
