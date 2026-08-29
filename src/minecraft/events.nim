## The tier-2 event WIRE FORMAT, shared by live emission and re-simulation.
##
## Forked from `src/ctf/events.nim`, with `SimEventKind` reduced to this
## game's fifteen kinds and the mandatory trailing summary row kept. The
## `Primitive` row is what makes this stream a full action trace for
## `cogamer-rl` - at most one row per tick, which is what an LLM-vs-RL ladder
## needs and what the replay deliberately does not carry.
##
## `SimEvent` never enters `gameHash`, so nothing here can affect determinism.

import std/json

import sim

proc key*(kind: SimEventKind): string =
  kind.eventKey()

proc jsonRow*(event: SimEvent): JsonNode =
  ## One JSON-lines row for a tier-2 sim event.
  result = newJObject()
  result["tick"] = %event.tick
  result["kind"] = %event.kind.key()
  result["what"] = %event.what
  result["why"] = %event.why
  result["x"] = %event.x
  result["y"] = %event.y
  result["z"] = %event.z
  result["amount"] = %event.amount
  result["content"] = %event.content

proc eventsJsonl*(events: openArray[SimEvent], ticks: int,
    summaryExtra: JsonNode = nil): string =
  ## The full JSON-lines stream: one row per event, then a summary.
  ##
  ## The trailing summary row is part of the contract, not decoration - it is
  ## how a reader distinguishes "this episode had no events" from "the file
  ## was truncated", and it carries the GameVersion the events were produced
  ## under so a consumer never has to infer it.
  var lines = newSeqOfCap[string](events.len + 1)
  for event in events:
    lines.add($event.jsonRow())
  var summary = newJObject()
  summary["type"] = %"summary"
  summary["ticks"] = %ticks
  summary["events"] = %events.len
  summary["gameVersion"] = %GameVersion
  if summaryExtra != nil:
    for key, value in summaryExtra:
      summary[key] = value
  lines.add($summary)
  result = ""
  for line in lines:
    result.add(line)
    result.add('\n')
