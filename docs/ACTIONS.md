# Actions and the reply format

A policy sends **one JSON object per turn**. The turn runs for exactly
`turnTicks = 20` ticks — a turn always costs 20 ticks even if you send one
action — so always fill the turn.

```json
{"actions": [{"act": "mine", "n": 1},
             {"act": "goto", "x": 13, "y": 20},
             {"act": "place_furnace"},
             {"act": "smelt_iron", "n": 2},
             {"act": "tunnel", "dir": "east", "n": 6}],
 "say": "iron in the wall and a table already down - furnace here, then east",
 "notes": "z=2 workshop (13,20). furnace next to it. lava (15,21)."}
```

## The seventeen primitives

`noop`, `move_north`, `move_east`, `move_south`, `move_west`, `mine`,
`dig_down`, `climb_up`, `place_block`, `place_crafting_table`,
`place_furnace`, `craft_planks`, `craft_sticks`, `craft_wooden_pickaxe`,
`craft_stone_pickaxe`, `craft_iron_pickaxe`, `smelt_iron`.

* **`move_<dir>`** sets `facing = dir` **and** steps one cell if that cell is
  walkable; if it is not, the cog only **turns**. A blocked move is a turn,
  not a no-op.
* **`mine`** acts on the cell the cog faces, on its own level. Wrong tier or
  an unmineable block spends the tick and reports why.
* **`dig_down`** breaks the floor. `z == 3` is bedrock floor; an existing
  shaft is a free descent with no drop; **lava below breaks the floor but does
  not move you**; bedrock below or too soft a pickaxe blocks; otherwise the
  drop is collected, the cell becomes a tunnel, the shaft is cut and the cog
  descends.
* **`climb_up`** needs a shaft at your exact `(x, y)` on the level above.
* **`place_block`** costs 1 cobblestone and fills the lava or water you face.
* **`place_crafting_table`** costs 4 planks, **`place_furnace`** 8
  cobblestone; both need the faced cell to be grass, sand or tunnel.

An inapplicable primitive is a **no-op that still costs its tick**. There is
no error, no repair and no free retry.

## The three macros

| Action | Expands to |
|---|---|
| `{"act":"move","dir":d,"n":k}` | up to `k` × `move_<d>` |
| `{"act":"tunnel","dir":d,"n":k}` | `k` × (`mine`, `move_<d>`) — 2 ticks per cell, and how you move underground |
| `{"act":"goto","x":X,"y":Y}` | the BFS path there through ground you have ALREADY SEEN, on THIS level |

The `goto` BFS runs over the known map of your current level as of turn start.
A cell is traversable only if its **known** block is grass, sand or tunnel —
so the driver never routes through lava and **never routes through the
unknown**. It ends **on** a traversable target, or **next to** a
non-traversable one **facing it**, which is exactly where you want to be
before `mine`. An unreachable target yields **zero** primitives and is
reported back as `unreachable`. `goto` never changes `z`.

Every macro is capped at `macroPrimitiveCap = 20` primitives, and the whole
expanded queue is truncated to 20. **Nothing carries over.**

## Caps

| Field | Type | Cap / domain |
|---|---|---|
| `actions` | array | **≤ 12 entries**. Entries past the cap are dropped and counted. Absent or empty = 20 `noop` ticks, and the reply is still **usable** |
| `actions[].act` | string | ≤ 24 runes; the 17 primitives plus `goto`, `move`, `tunnel`, lower-cased and `-`→`_` normalised |
| `actions[].x`, `.y` | integer | required iff `act == "goto"`; clamped to 0 … 31; a non-integer or absent value **drops the entry** |
| `actions[].dir` | string | required iff `act ∈ {move, tunnel}`; ≤ 6 runes; `north`/`east`/`south`/`west`, `n`/`e`/`s`/`w`, `up`→north, `down`→south, `left`→west, `right`→east; anything else drops the entry |
| `actions[].n` | integer | honoured on `move` (1…12), `tunnel` (1…10), `mine` (1…12), `dig_down` (1…3), `climb_up` (1…3), `craft_planks` (1…8), `craft_sticks` (1…4), `smelt_iron` (1…6) and `noop` (1…20); clamped; absent = 1; ignored elsewhere |
| `say` | string | ≤ 160 runes — the cog thinking out loud; drawn in the feed, never fed back to you |
| `notes` | string | ≤ 400 runes — a private scratchpad, echoed back to you only |
| the whole reply | bytes | ≤ 4096 read from the provider before parsing |

**Invalid actions are DROPPED, never rewritten.** Turning a malformed `goto`
into a `move_south` could walk the cog into lava on the game's own initiative,
so the entry is removed, counted in `repliesRepaired`, and reported back as
`dropped` next turn. Unknown top-level and per-action keys are ignored. A
reply with a valid `say` but no `actions` is usable. A reply that is not a
JSON object is a parse failure.

Every string that lands in the replay is truncated on **rune** boundaries,
never by byte index.

## The observation

```json
{
  "you": "Alpha",
  "turn": 21, "tick": 401, "ticks_left": 559, "turns_left": 27,
  "world": {"levels": 4, "size": 32, "view": 5, "region": 16,
            "level_labels": ["y=64 (surface)", "y=48 (stone)",
                             "y=32 (iron depth)", "y=12 (diamond depth)"],
            "legend": {"...": "..."}},
  "agent": {"x": 12, "y": 19, "z": 2, "level_label": "y=32 (iron depth)",
            "facing": "east", "tier": 2,
            "ahead": {"glyph": "i", "what": "iron ore", "x": 13, "y": 19,
                      "mineable_by_you": true},
            "below": {"known": false}},
  "inventory": {"log": 1, "planks": 5, "stick": 4, "cobblestone": 14,
                "coal": 3, "raw_iron": 0, "iron_ingot": 0, "diamond": 0},
  "tools": {"wooden_pickaxe": true, "stone_pickaxe": true, "iron_pickaxe": false},
  "near": {"table": true, "furnace": false},
  "view": ["#####", "#=c##", "#@i##", "#==t#", "###!#"],
  "region": ["????????????????", "..."],
  "nearest": {"iron_ore": {"x": 13, "y": 19, "d": 1}, "tree": null, "...": null},
  "known_ore": [{"what": "coal_ore", "z": 1, "x": 20, "y": 7, "d": null,
                 "seen_tick": 190}],
  "column": [{"z": 0, "label": "y=64 (surface)", "visited": true,
              "shaft_here": false}],
  "milestones": {"count": 6, "of": 11, "next": "iron_ore",
                 "unlocked": [{"id": "log", "tick": 14, "points": 1}],
                 "locked": ["iron_ore", "furnace", "iron_ingot",
                            "iron_pickaxe", "diamond"]},
  "last_plan": {"executed": ["mine", "move_east"], "truncated": false,
                "dropped": 0, "unreachable": 0,
                "blocked": [{"act": "mine", "why": "unmineable"}],
                "interrupted": ""},
  "notes": "z=2 workshop: table (13,20)..."
}
```

`view` is always `2r+1` strings of `2r+1` characters; `region` is always 16
strings of 16, of the **current level only**; `nearest` always has all twelve
keys (value or `null`); `column` always has exactly four entries;
`known_ore` is at most 24 entries across all four levels, sorted by `z`, then
distance, then `(y, x)`. `last_plan.executed` lists the **primitives** that
actually ran — macros already expanded — so you can see a `tunnel` get cut
short rather than guess.

**Hidden, always:** the episode seed; every cell never observed, on every
level; every block on a level you have not descended to; every generator
threshold; every future draw; your own score; `parMilestones`; and your own
real player name. Nothing about identity ever reaches a prompt.

## Fielding your own policy

A policy is just a prompt. Reuse the shipped image:

```bash
coworld upload-policy coworld-minecraft:latest --name my-minecraft \
  --run /bin/minecraft-player \
  --secret-env PLAYER_PROMPT="Get to the diamond. Nothing else is worth a tick."
```

`PLAYER_SCRIPTED=miner|scrounger` runs a scripted baseline out of the same
image instead.
