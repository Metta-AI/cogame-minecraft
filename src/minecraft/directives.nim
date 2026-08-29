## The reply schema: what a policy (LLM or scripted) may say, how a reply is
## parsed TOLERANTLY, and how an illegal entry is DROPPED rather than
## rewritten.
##
## Forked from `src/ctf/directives.nim`. Both policy kinds emit the SAME
## object through this one validator, which is what makes the bounded-orders
## test on the scripted baselines meaningful.
##
## RUNE DISCIPLINE. Every cap here is measured in RUNES and every truncation
## lands on a rune boundary. Slicing by BYTE index anywhere on the path to the
## replay is forbidden: a byte-truncated multi-byte character renders fine in a
## browser and then fails a strict UTF-8 parser.
##
## INVALID ACTIONS ARE DROPPED, NEVER REWRITTEN. Turning a malformed `goto`
## into a `move_south` could walk the cog into lava on the game's own
## initiative, so the entry is removed, counted in `repliesRepaired`, and
## reported back as `dropped` next turn. An entry past `maxActionsPerTurn` is
## dropped too, but it is a different fact about the reply and is counted
## apart, in `actionsDropped`.

import std/[json, strutils, unicode]

import sim_types

type
  ActKind* = enum
    ## The 17 primitives by name, plus the 3 macros.
    akPrimitive
    akGoto
    akMove
    akTunnel

  PlanAction* = object
    kind*: ActKind
    primitive*: Primitive
    facing*: Facing
    x*, y*: int
    n*: int

  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  Plan* = object
    actions*: seq[PlanAction]
    say*: string
    notes*: string
    source*: DirectiveSource
    latencyMs*: int
    dropped*: int       ## entries past `maxActionsPerTurn` (`actionsDropped`)
    repaired*: int      ## entries that did not validate (`repliesRepaired`)
    truncatedActions*: bool

  DirectiveError* = object of ValueError

const
  MacroNames* = ["goto", "move", "tunnel"]

proc sanitizeSay*(text: string): string =
  ## Capped at MaxSayRunes on a RUNE boundary first, then filtered to
  ## printable characters. Braces are excluded deliberately: the replay chat
  ## stream carries this game's control records as JSON objects and tells them
  ## apart from a cog's line by a leading `{`.
  result = ""
  for rune in text.truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    if value >= 32 and value != 127 and value != ord('{') and
        value != ord('}'):
      result.add($rune)
  result = result.replace("\n", " ").replace("\r", " ").strip()

proc sanitizeNote*(text: string): string =
  ## The private scratchpad, as it reaches the replay. Newlines collapse to
  ## spaces so one record stays one line.
  text.replace("\n", " ").replace("\r", " ").strip()
    .truncateRunes(MaxNoteRunes).replace("{", "(").replace("}", ")")

proc normalizeAct*(text: string): string =
  ## Lower-cased and `-` -> `_` normalised before matching.
  text.strip().truncateRunes(24).toLowerAscii().replace("-", "_")
    .replace(" ", "_")

proc parsePrimitive*(text: string): tuple[ok: bool, value: Primitive] =
  let key = normalizeAct(text)
  for primitive in Primitive:
    if $primitive == key:
      return (true, primitive)
  (false, pNoop)

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is
  ## what recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0:
        start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            discard
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first >= 0 and last > first:
    try:
      return parseJson(text[first .. last])
    except CatchableError as error:
      raise newException(DirectiveError, "reply is not JSON: " & error.msg)
  raise newException(DirectiveError, "reply contains no JSON object")

proc readInt(node: JsonNode, key: string): tuple[ok: bool, value: int] =
  if not node.hasKey(key):
    return (false, 0)
  let entry = node[key]
  case entry.kind
  of JInt: (true, entry.getInt())
  of JFloat: (true, int(entry.getFloat()))
  of JString:
    try: (true, parseInt(entry.getStr().strip()))
    except CatchableError: (false, 0)
  else: (false, 0)

proc nRangeFor(primitive: Primitive): tuple[lo: int, hi: int] =
  ## `n` is honoured only on the verbs the reply schema lists, and clamped
  ## into range. Absent = 1; ignored on every other verb.
  case primitive
  of pMine: (1, 12)
  of pDigDown: (1, 3)
  of pClimbUp: (1, 3)
  of pCraftPlanks: (1, 8)
  of pCraftSticks: (1, 4)
  of pSmeltIron: (1, 6)
  of pNoop: (1, 20)
  else: (1, 1)

proc parsePlanEntry(node: JsonNode, levelSize: int): tuple[ok: bool,
    action: PlanAction] =
  if node.kind != JObject:
    return (false, PlanAction())
  var actText = ""
  if node.hasKey("act") and node["act"].kind == JString:
    actText = node["act"].getStr()
  elif node.hasKey("action") and node["action"].kind == JString:
    actText = node["action"].getStr()
  if actText.len == 0:
    return (false, PlanAction())
  let key = normalizeAct(actText)
  let nRead = node.readInt("n")

  if key == "goto":
    let
      xRead = node.readInt("x")
      yRead = node.readInt("y")
    if not xRead.ok or not yRead.ok:
      return (false, PlanAction())
    return (true, PlanAction(kind: akGoto,
      x: clamp(xRead.value, 0, levelSize - 1),
      y: clamp(yRead.value, 0, levelSize - 1), n: 1))
  if key == "move" or key == "tunnel":
    if not node.hasKey("dir") or node["dir"].kind != JString:
      return (false, PlanAction())
    let dir = parseFacing(node["dir"].getStr().truncateRunes(6))
    if not dir.ok:
      return (false, PlanAction())
    let cap = if key == "move": 12 else: 10
    var count = if nRead.ok: nRead.value else: 1
    count = clamp(count, 1, cap)
    return (true, PlanAction(
      kind: (if key == "move": akMove else: akTunnel),
      facing: dir.facing, n: count))

  let primitive = parsePrimitive(actText)
  if not primitive.ok:
    return (false, PlanAction())
  let bounds = nRangeFor(primitive.value)
  var count = if nRead.ok: nRead.value else: 1
  count = clamp(count, bounds.lo, bounds.hi)
  (true, PlanAction(kind: akPrimitive, primitive: primitive.value, n: count))

proc parsePlan*(payload: JsonNode, maxActions, levelSize: int): Plan =
  ## Tolerant. Unknown top-level and per-action keys are ignored. A reply with
  ## a valid `say` but no `actions` is USABLE - the turn is spent idling and
  ## the narration is delivered. A reply that is not a JSON object is a parse
  ## failure.
  if payload.isNil or payload.kind != JObject:
    raise newException(DirectiveError, "reply is not a JSON object")
  result.actions = @[]
  result.source = dsLlm
  if payload.hasKey("say") and payload["say"].kind == JString:
    result.say = sanitizeSay(payload["say"].getStr())
  if payload.hasKey("notes") and payload["notes"].kind == JString:
    result.notes = sanitizeNote(payload["notes"].getStr())
  if payload.hasKey("actions") and payload["actions"].kind == JArray:
    var index = 0
    for entry in payload["actions"]:
      if index >= maxActions:
        result.truncatedActions = true
        inc result.dropped
        inc index
        continue
      inc index
      let parsed = parsePlanEntry(entry, levelSize)
      if parsed.ok:
        result.actions.add(parsed.action)
      else:
        ## Cause (b): the entry does not validate. Counted SEPARATELY from
        ## the over-cap drops above, because `results` reports the two as
        ## `actionsDropped` and `repliesRepaired` and they answer different
        ## questions about a policy.
        inc result.repaired

proc actionJson*(action: PlanAction): JsonNode =
  case action.kind
  of akPrimitive:
    result = %*{"act": $action.primitive}
    if action.n != 1:
      result["n"] = %action.n
  of akGoto:
    result = %*{"act": "goto", "x": action.x, "y": action.y}
  of akMove:
    result = %*{"act": "move", "dir": $action.facing, "n": action.n}
  of akTunnel:
    result = %*{"act": "tunnel", "dir": $action.facing, "n": action.n}

proc actionsJson*(plan: Plan): JsonNode =
  result = newJArray()
  for action in plan.actions:
    result.add(action.actionJson())

proc planBytes*(plan: Plan): int =
  ## The serialised directive's size, which `tests/test_minecraft_driver.nim`
  ## bounds at 1024 bytes for both scripted baselines.
  ($plan.actionsJson()).len

proc registerRecord*(slot: int, alias, policy, kind, baseline: string): string =
  ## The REDACTED registration record. The seat's prompt is NEVER written:
  ## only the policy label, the kind, and which baseline a scripted seat
  ## picked.
  $(%*{
    "k": "register",
    "slot": slot,
    "alias": alias,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc fallbackRecord*(turn, attempt: int, cause, detail: string): string =
  $(%*{
    "k": "fallback",
    "turn": turn,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

proc stopRecord*(tick: int, endRule: string): string =
  ## The load-bearing wall-clock / fault stop. A wall-clock fact cannot be
  ## re-derived from sim state, so it is written as one record applied by the
  ## SAME proc on record and on playback.
  $(%*{"k": "stop", "tick": tick, "endRule": endRule})

proc directiveRecord*(turn, tick, slot: int, alias: string, plan: Plan,
    executed: seq[string], truncated: bool, dropped, unreachable: int,
    blocked: seq[tuple[act: string, why: string]], interrupted: string,
    view: JsonNode): string =
  var executedJson = newJArray()
  for act in executed:
    executedJson.add(%act)
  var blockedJson = newJArray()
  for entry in blocked:
    blockedJson.add(%*{"act": entry.act, "why": entry.why})
  $(%*{
    "k": "directive",
    "turn": turn,
    "tick": tick,
    "slot": slot,
    "alias": alias,
    "source": $plan.source,
    "latency_ms": plan.latencyMs,
    "actions": plan.actionsJson(),
    "executed": executedJson,
    "truncated": truncated,
    "dropped": dropped,
    "unreachable": unreachable,
    "blocked": blockedJson,
    "interrupted": interrupted,
    "say": plan.say.truncateRunes(MaxSayRunes),
    "view": (if view.isNil: newJNull() else: view)
  })
