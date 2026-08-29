#!/usr/bin/env python3
"""Summarise a minecraft `.replay` as one strict-UTF-8 JSON object on stdout.

Python 3 standard library only: no Nim, no Docker, no emsdk. This is the JSON
view of the binary `COWLDMCR` replay the static wasm viewer parses, and it is
what phase 60's definition-of-done check reads instead of `jq .` on the raw
bytes:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null                  # strict UTF-8 JSON: ok
    jq -r '.protocol, .results.reason, .results.endRule' /tmp/ep.json
    jq -r '[.plans[]|select(.source=="llm")]|length, .fallbacks, (.says|length)' /tmp/ep.json

The replay stays binary on purpose: a JSON replay would mean rewriting
replays.nim, replay_runtime.nim, static_replay_worker.js and
wasm_replay_smoke.cjs — the machinery this fork exists to reuse.

How it reads the file WITHOUT a decoder for the whole record stream:

* the header is ASCII up to the config JSON, so the config is recovered by
  BRACE-MATCHING from the first `{` (the technique the starter's AGENTS.md
  documents for prod forensics);
* the CONTROL records — `register`, `directive`, `fallback`, `budget_guard`,
  `start`, `turnend`, `stop` and `result` — are UTF-8 JSON objects embedded
  verbatim in the chat records, so they are recovered the same way, by
  scanning the remaining bytes for balanced `{"k":...}` objects.

Nothing here needs the record framing, so it cannot drift when the framing
changes; it only needs the two things that are text.
"""

from __future__ import annotations

import json
import sys


def brace_match(data: bytes, start: int) -> tuple[dict | None, int]:
    """Decode one balanced ``{...}`` starting at ``start``.

    Returns ``(obj, end)`` where ``end`` is the index just past the object, or
    ``(None, start + 1)`` when the bytes there are not a decodable object.
    """
    depth = 0
    in_string = False
    escaped = False
    for i in range(start, len(data)):
        ch = data[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == 0x5C:      # backslash
                escaped = True
            elif ch == 0x22:      # quote
                in_string = False
            continue
        if ch == 0x22:
            in_string = True
        elif ch == 0x7B:          # {
            depth += 1
        elif ch == 0x7D:          # }
            depth -= 1
            if depth == 0:
                chunk = data[start:i + 1]
                try:
                    return json.loads(chunk.decode("utf-8")), i + 1
                except (UnicodeDecodeError, json.JSONDecodeError):
                    return None, start + 1
        elif depth == 0:
            # A stray byte before any brace: not the start of an object.
            return None, start + 1
    return None, len(data)


MILESTONE_IDS = [
    "log", "planks", "crafting_table", "wooden_pickaxe", "cobblestone",
    "stone_pickaxe", "iron_ore", "furnace", "iron_ingot", "iron_pickaxe",
    "diamond",
]


MAGIC = b"COWLDMCR"


def read_header(data: bytes) -> tuple[str, str, int]:
    """Decode the fixed header and return (gameName, gameVersion, offset).

    The header is `magic + u16 formatVersion + string gameName +
    string gameVersion + u64 timestamp`, where a string is a little-endian
    u16 length followed by its bytes. Reading it EXACTLY matters: the earlier
    version scanned the first ASCII digit run after the game name, which
    silently ran into the timestamp whenever its first byte happened to be an
    ASCII digit - a one-in-ten flake that reported a version like "17".
    """
    if not data.startswith(MAGIC):
        raise ValueError("not a %s replay" % MAGIC.decode())
    offset = len(MAGIC) + 2

    def read_string(off: int) -> tuple[str, int]:
        length = data[off] | (data[off + 1] << 8)
        off += 2
        return data[off:off + length].decode("utf-8"), off + length

    game_name, offset = read_string(offset)
    game_version, offset = read_string(offset)
    offset += 8                                    # the u64 timestamp
    return game_name, game_version, offset


def summarise(path: str) -> dict:
    data = open(path, "rb").read()
    protocol = "minecraft/v1"
    game_name, game_version, header_end = read_header(data)
    if game_name != "minecraft":
        raise ValueError("replay is for %r, not minecraft" % game_name)

    first = data.find(b"{", header_end)
    config: dict = {}
    cursor = 0
    if first >= 0:
        config, cursor = brace_match(data, first)
        config = config or {}

    plans: list[dict] = []
    says: list[str] = []
    fallbacks = 0
    registers: list[dict] = []
    budget_guards = 0
    stops: list[dict] = []
    turns = 0
    results: dict = {}
    i = cursor
    while True:
        i = data.find(b'{"k":', i)
        if i < 0:
            break
        obj, nxt = brace_match(data, i)
        i = nxt
        if not isinstance(obj, dict):
            continue
        kind = obj.get("k")
        if kind == "directive":
            plans.append({
                "turn": obj.get("turn"),
                "tick": obj.get("tick"),
                "source": obj.get("source"),
                "latency_ms": obj.get("latency_ms"),
                "actions": obj.get("actions") or [],
                "executed": obj.get("executed") or [],
                "truncated": obj.get("truncated"),
                "dropped": obj.get("dropped"),
                "unreachable": obj.get("unreachable"),
                "interrupted": obj.get("interrupted"),
                "say": obj.get("say") or "",
            })
            if obj.get("say"):
                says.append(obj["say"])
        elif kind == "fallback":
            fallbacks += 1
        elif kind == "register":
            registers.append(obj)
        elif kind == "budget_guard":
            budget_guards += 1
        elif kind == "turnend":
            turns += 1
        elif kind == "stop":
            stops.append(obj)
        elif kind == "result":
            results = obj.get("results", obj)

    names = [p.get("name", "") for p in (config.get("players") or [])]
    seats = int(config.get("num_agents") or len(names) or 1)
    identities = ["Alpha", "Beta", "Gamma", "Delta"]
    aliases = identities[:seats]

    milestones = []
    ids = results.get("milestoneIds") or MILESTONE_IDS
    unlocked = results.get("milestoneUnlocked") or []
    ticks = results.get("milestoneTick") or []
    points = results.get("milestonePoints") or []
    for index, name in enumerate(ids):
        milestones.append({
            "id": name,
            "points": points[index] if index < len(points) else 1 << index,
            "unlocked": bool(unlocked[index]) if index < len(unlocked) else False,
            "tick": ticks[index] if index < len(ticks) else -1,
        })

    return {
        "protocol": protocol,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "variant": config.get("variant") or "standard",
        "names": names,
        "aliases": aliases,
        "policyKinds": [r.get("kind", "") for r in registers],
        "tickCount": int(results.get("finalTick") or turns * int(
            config.get("turnTicks") or 20)),
        "turnsPlayed": int(results.get("turnsPlayed") or turns),
        "plans": plans,
        "says": says,
        "fallbacks": fallbacks,
        "budgetGuards": budget_guards,
        "stops": stops,
        "milestones": milestones,
        "results": results,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: replay_summary.py <path.replay>", file=sys.stderr)
        return 2
    out = summarise(argv[1])
    # ensure_ascii=False keeps a non-ASCII policy label or note as real UTF-8,
    # which is exactly what the strict-parse check downstream is testing.
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
