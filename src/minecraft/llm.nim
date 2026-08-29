## Claude-backed play. A policy is just a prompt: the game server composes the
## seat's own observation plus that seat's PLAYER_PROMPT and asks Claude what
## the cog does for the next twenty ticks.
##
## Forked from `src/ctf/llm.nim` with NO behaviour change - the credential
## ladder, the Bedrock model rotation, the fence-tolerant JSON extraction, the
## assistant-turn `{` prefill and the rune-boundary truncation are all that
## file's, because they are all scar tissue from real hosted failures.
##
## THE DECISION HAPPENS IN THE GAME SERVER, NOT THE PLAYER CONTAINER. That is
## the only shape that works on this platform: the `anthropic_api_key` coworld
## secret is injected into the GAME pod, phase 60 greps the GAME log, and
## `docker_smoke.sh` forwards `ANTHROPIC_API_KEY` to the game container only.
##
## Credentials, in order of preference:
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to
## the scripted layer INSTANTLY, with no network wait - which is what lets
## offline certification finish in seconds.

import std/[json, os, strutils]

import bitworld/runtime
import curly

import sim_types

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  JsonPrefill* = "{"
    ## The assistant-turn prefill. Both Anthropic Messages and Bedrock invoke
    ## accept it; it is re-prefixed before parsing and guarded against a
    ## provider that echoes it. The fix for "cut off at max_tokens" is the
    ## prefill, never a bigger cap.

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "minecraft llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order; BEDROCK_MODEL pins
  ## one. `us.anthropic.claude-sonnet-4-6` is deliberately NOT a candidate: it
  ## times out on every sidecar call (cogame-raid round 2, 2026-08-23).
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
  ]

proc tryNextBedrockModel*(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "minecraft llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "minecraft llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "minecraft llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside "falling
    ## back" in decide.nim: "LLM provider is unavailable".
    echo "minecraft llm: no credentials - the LLM provider is unavailable; ",
      "every turn is falling back to the scripted layer"

proc requestFor*(client: LlmClient, system, user: string): tuple[url: string,
    headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live, with
  ## the assistant-turn `{` prefill.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [
      {"role": "user", "content": user},
      {"role": "assistant", "content": JsonPrefill}
    ]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc withPrefill*(text: string): string =
  ## Re-prefixes the prefill before parsing, guarded against a provider that
  ## echoes it.
  let trimmed = text.strip()
  if trimmed.startsWith(JsonPrefill):
    return trimmed
  JsonPrefill & trimmed

proc textOf*(client: LlmClient, response: Response, error, url: string): string =
  ## The text of one batched reply, or an LlmError describing why there is
  ## none. Auth failure disables the client for the rest of the episode;
  ## model-access denial and throttling rotate the Bedrock model instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(LlmError, "llm auth failed (" & $response.code &
      ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  var text = ""
  if payload.hasKey("content") and payload["content"].kind == JArray:
    for contentBlock in payload["content"]:
      if contentBlock{"type"}.getStr() == "text":
        text.add(contentBlock{"text"}.getStr())
  ## The whole reply is capped at MaxReplyBytes read from the provider before
  ## parsing: a BYTE cap, as the note's reply-schema table specifies, taken on
  ## a rune boundary so it can never split a codepoint. Capping 4096 RUNES
  ## would admit up to 16 KiB of 4-byte codepoints.
  result = text.truncateBytes(MaxReplyBytes)
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result and
      JsonPrefill notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

const SystemPrompt* = """
You are one cog alone in a blocky world of four stacked levels. The ONLY thing
scored is how far you climb the ObtainDiamond ladder before the clock runs out:

  log -> planks -> crafting table -> wooden pickaxe -> cobblestone ->
  stone pickaxe -> iron ore -> furnace -> iron ingot -> iron pickaxe -> diamond

Each rung is worth DOUBLE all the rungs below it put together. Getting ONE rung
higher beats anything else you could possibly do. Nothing else scores. Nothing
is hunting you. You never eat, drink or sleep. You only run out of time.

THE FOUR LEVELS
  z=0  y=64  SURFACE        grass, trees, water, sand, the odd boulder
  z=1  y=48  STONE          stone and coal, some natural caves
  z=2  y=32  IRON DEPTH     stone, iron, coal, and LAVA
  z=3  y=12  DIAMOND DEPTH  stone, diamond, iron, and a lot of LAVA
You go DOWN with "dig_down" and back up with "climb_up", and only through a
shaft you dug yourself. YOU CANNOT SEE THROUGH THE FLOOR: a level you have not
been to is all "?". Wood only exists on the surface.

GLYPHS
  .  grass   ,  sand   ~  water   T  oak tree   #  stone   =  tunnel/cave floor
  c  coal    i  iron   D  diamond !  LAVA       B  bedrock t  crafting table
  f  furnace v  shaft DOWN from here            ^  shaft UP from here
  @  you     ?  never seen
You see 11x11 on the surface and only 5x5 underground.

PICKAXE TIERS - this IS the tech tree
  hands        chop trees
  wooden pick  stone, boulders, coal
  stone pick   iron ore
  iron pick    DIAMOND
Mining something you lack the tier for wastes the tick and tells you why.

RECIPES
  craft_planks          1 log -> 4 planks              anywhere
  craft_sticks          2 planks -> 4 sticks           anywhere
  place_crafting_table  4 planks                       puts a table down
  craft_wooden_pickaxe  3 planks + 2 sticks            next to a table
  craft_stone_pickaxe   3 cobblestone + 2 sticks       next to a table
  craft_iron_pickaxe    3 iron ingots + 2 sticks       next to a table
  place_furnace         8 cobblestone                  puts a furnace down
  smelt_iron            1 raw iron + 1 coal -> 1 ingot next to a furnace
  place_block           1 cobblestone                  fills the lava or water
                                                       you are facing
"Next to" means within one cell, on YOUR level. Carry spare planks: a second
table costs 4 planks and saves you six turns of walking back up.

LAVA
Walking into lava kills you instantly and ends the run. Digging down ONTO lava
does NOT kill you - you break the floor, see the lava, and stay put. Lava
appearing right beside you ENDS YOUR TURN and throws the rest of your plan away.

WHAT YOU SEND
One JSON object with up to 12 actions. They run one per tick, in order, for
exactly 20 ticks - and A TURN ALWAYS COSTS 20 TICKS, even if you send one
action. Always fill the turn.
  {"act":"goto","x":21,"y":9}     walk there through ground you have already
      seen, on THIS level. Stops ON the target, or NEXT TO it FACING it, which
      is exactly where you want to be before "mine".
  {"act":"tunnel","dir":"east","n":6}   mine, step, mine, step - six times.
      This is how you move underground: 2 ticks per cell.
  {"act":"move","dir":"north","n":4}    step up to 4 times. Moving into a wall
      just TURNS you to face it.
  {"act":"mine","n":3}       mine the cell you are FACING, three times.
  {"act":"dig_down","n":2}   break the floor and drop a level, twice.
  {"act":"climb_up"} {"act":"place_block"} {"act":"place_crafting_table"}
  {"act":"place_furnace"} {"act":"craft_planks","n":2} {"act":"craft_sticks"}
  {"act":"craft_wooden_pickaxe"} {"act":"craft_stone_pickaxe"}
  {"act":"craft_iron_pickaxe"} {"act":"smelt_iron","n":3} {"act":"noop"}

HOW YOU ARE SCORED
Only the ladder. Reaching the same rung SOONER is the tie-break, and only the
tie-break. Blocks mined, distance walked and time survived are worth nothing.

REPLY FORMAT
Reply with ONE JSON object and NOTHING else. Your reply MUST begin with the
character { and end with }. No prose, no markdown, no code fences.
{"actions":[{"act":"tunnel","dir":"east","n":6}],"say":"<=160 chars","notes":"<=400 chars"}
"""

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how
  ## much weight it carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, viewJson: string): string =
  operatorBlock(operatorPrompt) & viewJson
