# cogame-minecraft — design note (2026-08-29)

**Starter: `Metta-AI/coworld-ctf`** (paintbot), mounted read-only at `/workspace/starters/coworld-ctf`
and read for this note. **Every convention there holds here unless this note says otherwise.** That
means: Nim throughout; the `src/ctf/` module split (`sim.nim` importing and re-exporting the sim
modules; `sim_types.nim` owning `GameVersion` (`src/ctf/sim_types.nim:21`) and `TargetFps* = 24`
(`:376`) with its prepend-only changelog-comment discipline; the flatty wire types whose field order
is sacred; the rune caps `MaxNoteRunes` / `MaxSayRunes` / `MaxPromptRunes` (`:794-799`)); the mummy
HTTP/websocket server implementing the Coworld contract, including its `wallClockBudgetSeconds` stop
at `src/ctf/server.nim:1407-1417`; the `decide.nim` / `directives.nim` / `llm.nim` / `baselines.nim`
/ `control.nim` commander layer with its one-batch-per-turn shape (`src/ctf/decide.nim:427`
`engine.client.curl.makeRequests`), its `attempt1Ms` / `retryMs` / `turnBudgetMs` / `turnSpacingMs`
deadlines (`decide.nim:384-389, 406, 421-427`), its budget guard (`decide.nim:328-346`), its tolerant
JSON extraction, its rune truncation and its fallback ladder with the exact log phrasing
(`decide.nim:463` "failed, falling back if it fails again" for attempt 1; `:491` "falling back" only
on the second failure); the achievement ledger the starter already owns (`recordAchievement` at
`src/ctf/roster.nim:640-648`, `earnedAchievements` serialised at `roster.nim:828`); the binary
`COWLDCTF` replay of *inputs plus a per-tick `gameHash`* (`src/ctf/replays.nim:142`), re-simulated by
**the same sim module** compiled to wasm by `replay-viewer/config.nims`; the `client/` broadcast
chrome (`chrome_common.js` + `broadcast_core.js` + `replay_broadcast.html` with its
`window.PaintballChrome.install(PB_CTX)` splice hook at `client/replay_broadcast.html:4330-4337` and
the appended-game-block banner at `:4344`); nimby + `Dockerfile` + `Dockerfile.replay-viewer` +
`tools/build_replay_viewer.sh`; and the Nim test suite with its four shards (`tests/shard_1..4.nim`,
`tests/config.nims`).

Starter choice, one line: **this is a single-agent real-time tick loop whose rules are written into
this repo — the first row of the starter table** (`prompts/10-design.md` §Starter table: "any
real-time game loop (grid OR continuous physics), new rules written for this coworld"). It is
deliberately **not** the `cogame-moba` bit-exact-port row, and that is a **rail the coordinator
already set and this note does not revisit**: none of the six starters can host Malmo, a JVM
Minecraft server, MineRL's pixel pipeline or MineDojo's task suite, and the static wasm replay viewer
is a non-optional pin — so this coworld is an **in-spirit reimplementation** of the ObtainDiamond
problem as its own deterministic seeded Nim sim on the paintbot stack. No upstream code is vendored,
no upstream number is claimed as reproduced, and no score here is comparable to a published MineRL or
VPT figure. Every divergence is enumerated in §Sim module → "Documented divergences" and mirrored into
`docs/PORTING-MINECRAFT.md`. The precedent for forking paintbot for a single-seat benchmark ladder is
`runs/2026-08-28-crafter/design.md`, `runs/2026-08-28-nethack/design.md` and
`runs/2026-08-28-atari-57/design.md`, all on this same starter.

**How this differs from the already-shipped `cogame-crafter`**, deliberately and on every axis that
matters: crafter is one flat 64 × 64 world with four vitals, day/night, zombies and 22 shallow
achievements, and its score is *how many things you did before you starved*. This game has **no
vitals, no hunger, no thirst, no sleep, no day/night and no mobs at all**. It is a **four-level
stacked world** (surface / stone / iron depth / diamond depth) you descend by mining through the
floor, its score is the **eleven-rung ObtainDiamond ladder** where every rung is worth double every
rung beneath it combined, and the only pressure is **the deadline** — 960 ticks and then the run is
over wherever you stand. The watchable artifact is not a survival story, it is a **milestone
timeline**: eleven timestamps and how deep the cog got before the clock ran out. Crafter asks "can it
stay alive"; this asks "how far down the tech tree can it get, and how fast".

Where this note departs from coworld-ctf it says so. The departures are: the rules are mining,
descent and crafting rules, not paintbot's (§Sim module lists what is deleted); the board is
**four stacked 32 × 32 integer cell grids** built by a seeded integer-noise generator, so ctf's pixel
arena, procedural map generator, map pool, map editor and mapkit are deleted; there is **one seat, not
eight**, and no teams; the seat is **partially observed** through a depth-dependent egocentric window,
so ctf's raycast fog is replaced by a plain rectangular visibility rule per level; the **world is much
larger than the frame**, so — unlike the fixed-arena forks — `#viewpanel` (zoom bar + minimap) is
**kept** (§Viewer); and `MaxSayRunes` / `MaxNoteRunes` are re-pinned (§Decisions → reply schema).

### Source idea (verbatim)

> SA Minecraft — MineRL ObtainDiamond and MineDojo: the real game, the real tech tree, and a camera you have to aim
>
> Single-agent coworld over MineRL (ObtainDiamond / BASALT tasks) and MineDojo (thousands of language-specified tasks, plus the open-ended creative set). Real Minecraft via Malmo: first-person pixels, continuous camera, discrete keys; ObtainDiamond is the famous long-horizon milestone (log → planks → table → pickaxe → stone → iron → diamond); BASALT tasks (find cave, build a house, pen animals) are judged by human/LLM preference rather than reward. VPT and Voyager are the reference agents.
>
> Seats: 1
> Motive: milestone score (ObtainDiamond) or judged task completion (BASALT/MineDojo)
> Policy interface: per-frame keys + camera — heavy; LLM agents work through a skill library (Voyager-style), which is the realistic coworld interface
> Fills gap: the most recognisable open-ended environment; a judged-task league would be the first non-score coworld on the site
> Integrity: seeded worlds; milestone verification from game state; judged tasks need a fixed rubric + LLM judge with audit.
>
> Replay plan (watchability): it's Minecraft — first-person video; milestone timeline.
>
> Source: github.com/minerllabs/minerl; github.com/MineDojo/MineDojo; Malmo.

### Design pins, and where each is satisfied

| Pin (`playbooks/make-coworld.md` §Phase 0 / `docs/SPEC.md` §Design pins) | Where |
|---|---|
| Starter by game shape | `coworld-ctf` — real-time tick loop, rules written into this repo (title paragraph) |
| Public `Metta-AI/cogame-minecraft` | §Packaging (created `--public`; `source-resolves` 404s on private) |
| LLM policy **and** scripted baseline day one, one image, env-switched | §Decisions (`PLAYER_PROMPT` vs `PLAYER_SCRIPTED=miner\|scrounger`) |
| Static wasm replay viewer, never a pod | §Viewer (`replay_viewer.bundle = static-replay-viewer`, `tools/build_replay_viewer.sh`) |
| Starter chrome verbatim, real art | §Viewer (chrome provenance, byte-for-byte `chrome_common.js`, starter art + install-time bakes) |
| Two name spaces | §The game → Seats and aliases (in-game alias `Alpha`; real policy names spectator-side only) |
| Degrade never hang, play inside 60 % of 1200 s | §Decisions (typical 199 s, worst 577 s, engine stop 660 s, budget 720 s) |
| `num_agents` in every variant **and** the cert fixture, inside `game_config` | §Packaging — `num_agents: 1`, three times |
| Per-turn LLM call budget stated (single seat) | §Decisions (exactly one request per turn, two with the retry; ≤ 96 per episode) |
| Replay bytes self-sufficient | §Server (config JSON, joins, per-turn plans, chats, per-tick hashes, seed, variant) |
| Rune-boundary truncation on every free-text field | §Decisions (reply schema) |
| Seeded worlds + milestone verification from game state (the idea's integrity note) | §Sim module (the world is a pure hash of `(seed, variant)`; the seat never sees `seed` or an unexplored cell); §The game → Milestones (every rung is a predicate over sim state, never a self-report); §Server (per-tick `gameHash` chain re-checked in the browser) |
| Milestone score (the idea's motive) | §The game → Scoring — the eleven-rung ObtainDiamond ladder as a doubling bitmask, speed as the tie-break |

**There is no `OPEN` section.** Every rule the idea left open — seat count, the ladder's rungs and
their values, the tie-break, the world's shape, the observation, the action set, the variants — is
decided in this note, and the two the coordinator pinned (starter, and "no judged BASALT tasks in
v1") are carried through unchanged.

---

## The game

One cog stands in the middle of a green field with nothing in its hands. Underneath it are three more
floors of the world it cannot see: **stone**, then **iron depth**, then **diamond depth**. There is
nothing alive down there, nothing hunting it, nothing to eat and nowhere to sleep. There are eleven
things it has never done, in a fixed order, and each one needs the one before it:

**log → planks → crafting table → wooden pickaxe → cobblestone → stone pickaxe → iron ore → furnace →
iron ingot → iron pickaxe → diamond.**

That is MineRL's ObtainDiamond ladder, rung for rung. The cog has **960 ticks**. When they are gone
the run stops wherever it stands, and the only thing the league reads is **how far up the ladder it
got, and how fast**. The whole game is the arithmetic of the descent: every block of stone costs a
tick, every trip back to the surface for forgotten planks costs six turns, and the diamonds are at
the bottom of a world you have to cut a hole through to reach.

### Seats and aliases

- **`num_agents` = 1.** Exactly one seat, always — in both manifest variants and in the certification
  fixture. This is the idea's own "Seats: 1", and it is what ObtainDiamond is: a single-agent
  long-horizon benchmark. Every episode is a solo run; policies are compared across episodes and
  across seeds, never within one episode.
- **Two name spaces.** In-game the seat is **`Alpha`** — `IdentityNames[0]` (`src/ctf/roster.nim:64-65`
  is `["alpha", "beta", …]`), title-cased by `seatAlias(slot)`. That alias is the only name that
  appears in an observation, in a prompt, in a `say`, or on the board. The seat's **real
  policy/player name** (`daveey`, `daveey-1`, `Baseline (1)`) lives only in `results.names`, in the
  replay's join record, and spectator-side in the viewer's scorebug plate and endcard.
  `showPlayerLabels` is **false**, as in the starter's paintball variant, so nothing drawn on the
  board leaks an identity. With one seat there is nobody to meta-game against, but the pin is
  satisfied both ways, not either way: the alias is what the model sees, the real name is what the
  spectator sees.

### The world: four stacked levels

**`levelCount = 4`, `levelSize = 32`.** Four 32 × 32 grids stacked in `z`, each indexed `(x, y)` with
`x` the column `0 … 31` (west → east) and `y` the row `0 … 31` (north → south); `(0, 0)` is the
north-west corner of every level. The four levels carry Minecraft's own y-labels, and those labels are
what the seat and the spectator both read:

| `z` | Label the seat sees | What is down there |
|---|---|---|
| 0 | `y=64 (surface)` | grass, sand, water, oak trees, the odd stone boulder |
| 1 | `y=48 (stone)` | stone, coal ore, natural caves |
| 2 | `y=32 (iron depth)` | stone, iron ore, coal ore, caves, **lava** |
| 3 | `y=12 (diamond depth)` | stone, **diamond ore**, iron ore, caves, a lot of **lava** |

The outermost ring of every level (`x ∈ {0, 31}` or `y ∈ {0, 31}`) is **`bedrock`** — impassable,
unmineable, unplaceable — so the cog can never leave the world and no generator needs an
out-of-bounds branch. The playable interior is 30 × 30 = 900 cells per level; `cellsTotal` is the
constant **4096** (4 × 1024, bedrock included), which is what `results.cellsSeen` is a fraction of.

**A cell holds exactly one block.** The closed block enum, its glyph and its rules — `tier` is the
lowest pickaxe tier that can mine it (`0` = bare hands, `1` = wooden, `2` = stone, `3` = iron, `—` =
not mineable at all):

| Block | Glyph | Walkable | Tier | Drops | Becomes |
|---|---|---|---|---|---|
| grass | `.` | yes | — | — | — |
| sand | `,` | yes | — | — | — |
| water | `~` | no | — | — | — (`place_block` fills it) |
| oak tree | `T` | no | 0 | **3 log** | grass |
| stone | `#` | no | 1 | 1 cobblestone | tunnel |
| coal ore | `c` | no | 1 | 1 coal | tunnel |
| iron ore | `i` | no | 2 | 1 raw iron | tunnel |
| diamond ore | `D` | no | 3 | **1 diamond** | tunnel |
| tunnel / cave floor | `=` | yes | — | — | — |
| lava | `!` | **yes** | — | — | stepping in is **instant death** |
| bedrock | `B` | no | — | — | — |
| crafting table | `t` | no | — | — | — (placed) |
| furnace | `f` | no | — | — | — (placed) |

Two more glyphs are **overlays**, not blocks — they describe the *floor and ceiling* of a cell rather
than the cell itself: **`v`** means a shaft goes **down** from this cell (the cog can `dig_down`
through it for free) and **`^`** means a shaft goes **up** from it (the cog can `climb_up`). A cell
with both reads `v`. **`@`** is the cog itself and **`?`** is a cell it has never seen. Those
**seventeen glyphs** are the whole vocabulary the seat ever reads and the whole vocabulary the
viewer's inset ever draws.

**Shafts.** `shaftDown[z][x][y]` is a boolean per cell, false everywhere at generation and set only by
a successful `dig_down`. The cell `(x, y, z+1)` directly beneath a shaft reads `^` from below. Shafts
are the only vertical connection in the world: **there is no free falling, no ladders, no climbing a
wall.** You go down where you cut a hole and you come up the same hole.

**The cog** has a position `(x, y, z)`, a `facing ∈ {north, east, south, west}` (world frame:
`north` = −y, `south` = +y, `east` = +x, `west` = −x), an inventory and three tool flags. There is
**no health bar** — the cog is alive until it walks into lava, and then it is not.

- **Inventory**, each an integer `0 … 64` (a Minecraft stack): `log`, `planks`, `stick`,
  `cobblestone`, `coal`, `raw_iron`, `iron_ingot`, `diamond`. All start at **0**. A collection that
  would exceed 64 is capped and still unlocks its milestone.
- **Tools**, each a boolean, all false at start: `wooden_pickaxe`, `stone_pickaxe`, `iron_pickaxe`.
  **`tier` = 3 if `iron_pickaxe` else 2 if `stone_pickaxe` else 1 if `wooden_pickaxe` else 0.** Tools
  **never break** (a stated divergence from Minecraft — durability would add a resource-management
  axis the ladder does not need).

### World generation (seeded, integer-only, no floats)

Three **integer value-noise fields** per level — `cave`, `vein`, `surface` — each built on a lattice
of stride 8 whose corner values are `mix64(seed, fieldSalt, gx, gy) mod 1024` and bilinearly
interpolated in 16-bit fixed point, yielding an integer `0 … 1023` per cell. `fieldSalt` is
`1 + 3·z + f` for field index `f ∈ {0, 1, 2}`. Nothing here is floating point (§Sim module → Integer
arithmetic), so every field is bit-identical native and in wasm.

**Surface (z = 0)**, for each interior cell in ascending `(y, x)`, first match wins — `W` is the
`cave` field re-read as a water field, `T` the `vein` field re-read as a tree field, `H` the `surface`
field:

1. `W > 700` → **water**
2. `W > 650` → **sand**
3. `T > 660` → **oak tree**
4. `H > 900` → **stone** (a boulder outcrop, so a wooden pickaxe has something to bite on before the
   cog ever digs down)
5. else → **grass**

**Underground (z ∈ {1, 2, 3})**, for each interior cell in ascending `(y, x)`, first match wins — `C`
is the `cave` field, `V` the `vein` field, and every chance below is a per-cell draw of
`mix64(seed, 40 + 4·z + k, x, y) mod 1000` with a distinct `k` per ore:

1. `C > caveThreshold[z]` → **tunnel** (a natural cave)
2. `C < 120` and `draw(k=0) < lavaChance[z]` → **lava**
3. `V > veinThreshold` and `draw(k=1) < oreAChance[z]` → **oreA[z]**
4. `V > veinThreshold` and `draw(k=2) < oreBChance[z]` → **oreB[z]**
5. else → **stone**

with `veinThreshold = 600` in both variants and the per-level table (values are the `standard`
variant; `deepcut` multiplies every ore and lava chance by 3/2 and is tabulated in §Variants):

| `z` | `caveThreshold` | `lavaChance` ‰ | `oreA` / chance ‰ | `oreB` / chance ‰ |
|---|---|---|---|---|
| 1 | 880 | 0 | coal ore / 180 | coal ore / 0 |
| 2 | 850 | 12 | iron ore / 140 | coal ore / 80 |
| 3 | 830 | 30 | diamond ore / 70 | iron ore / 110 |

Then a **playability post-pass**, deterministic and in this order — without it a seed can be
unwinnable, and an unwinnable seed makes a benchmark meaningless:

1. The 3 × 3 block centred on **(16, 16)** at `z = 0` is forced to **grass**; the cog spawns at
   **(16, 16, 0)** facing **south**.
2. If no `oak tree` lies within Chebyshev radius 8 of `(16, 16)` on `z = 0`, the first `grass` cell
   (ascending `(y, x)`) at Chebyshev distance exactly 5 becomes an `oak tree`; and while
   `count(oak tree on z=0) < 6`, the first `grass` cell at ascending `(y, x)` with no tree within
   Chebyshev 2 becomes an `oak tree`. **Wood exists only on the surface**, so a wood-poor seed is a
   dead seed.
3. The cell `(16, 16, 1)` directly beneath spawn is forced to **stone** — the first `dig_down` always
   yields the cobblestone rung and never drops the cog into a cave or onto lava on tick one.
4. **Global minima per level**, converting the `stone` cell with the highest `vein` value (ties by
   ascending `(y, x)`) into the missing block, in this order:
   `z=1`: `count(coal ore) ≥ 12`. `z=2`: `count(iron ore) ≥ 14`, then `count(coal ore) ≥ 6`.
   `z=3`: `count(diamond ore) ≥ 8`, then `count(iron ore) ≥ 6`.
5. **No lava seals a level.** For each of `z ∈ {2, 3}`, if the count of non-`bedrock`, non-`lava`
   interior cells is below 700, the `lava` cells with the highest `cave` value are converted back to
   `stone` until it is 700. A level is always at least 78 % diggable.

The result: **every seed is completable** (any non-bedrock, non-lava block can be tunnelled to from
any other with the right pickaxe, and every level has more ore than a run needs), the world is a pure
function of `(seed, variant)`, and the seat is never told any of it (§Decisions → observation).

### The seventeen actions

Exactly these seventeen primitives, by name, and nothing else is a primitive:

`noop`, `move_north`, `move_east`, `move_south`, `move_west`, `mine`, `dig_down`, `climb_up`,
`place_block`, `place_crafting_table`, `place_furnace`, `craft_planks`, `craft_sticks`,
`craft_wooden_pickaxe`, `craft_stone_pickaxe`, `craft_iron_pickaxe`, `smelt_iron`.

- **`move_<dir>`** sets `facing = dir` **and** steps one cell in `dir` **on the current level** if that
  cell is walkable; if it is not, the cog only turns. (This is the semantics an implementer guesses
  wrong: a blocked move is a *turn*, not a no-op.) Stepping into `lava` kills the cog on that tick.
- **`mine`** acts on the cell the cog faces, on the current level. If that block's `tier` is `—`, or
  the cog's `tier` is below the block's, nothing happens except a `blocked` event
  (`why ∈ {no_tier, unmineable}`) and the spent tick. Otherwise the drop is added to the inventory and
  the block becomes what its row says.
- **`dig_down`** breaks the floor. Let `B` be the block at `(x, y, z+1)`.
  1. `z == 3` → `blocked{why: "bedrock_floor"}`; nothing happens.
  2. `shaftDown[z][x][y]` is already true → the cog descends to `(x, y, z+1)`, free, no drop.
  3. `B == lava` → the floor breaks, **the cog does not descend**, `(x, y, z+1)` becomes permanently
     known lava, a `lava` event and `blocked{why: "lava_below"}` fire, and the turn ends
     (§Resolution order, step 8).
  4. `B == bedrock` → `blocked{why: "unmineable"}`.
  5. `B`'s tier is above the cog's tier → `blocked{why: "no_tier"}`.
  6. otherwise → `B`'s drop is collected, `(x, y, z+1)` becomes `tunnel`,
     `shaftDown[z][x][y] = true`, and the cog descends to `(x, y, z+1)` keeping its facing.
  **Digging down onto lava is survivable; walking into lava you can see is not.** That asymmetry is
  deliberate: the seat cannot see through the floor, so a blind descent must never be an instant
  loss, while a step into a cell it *can* see is a policy error and is punished as one.
- **`climb_up`** requires `z > 0` and `shaftDown[z-1][x][y]` true; the cog ascends to `(x, y, z-1)`.
  Otherwise `blocked{why: "no_shaft"}`.
- **`place_block`** costs **1 cobblestone** and turns the faced cell into `stone` if that cell is
  `lava` or `water`. This is how you bridge, and it is the only way to un-kill a lava cell.
- **`place_crafting_table`** costs **4 planks**; **`place_furnace`** costs **8 cobblestone**. Both
  require the faced cell to be `grass | sand | tunnel` and turn it into `crafting table` / `furnace`.
- **Crafting.** `craft_planks` and `craft_sticks` need nothing but the materials. The three pickaxe
  recipes need a `crafting table` within Chebyshev distance 1 **on the same level** (`near.table`);
  `smelt_iron` needs a `furnace` within Chebyshev distance 1 on the same level (`near.furnace`).

  | Recipe | Costs | Yields | Also needs |
  |---|---|---|---|
  | `craft_planks` | 1 log | 4 planks | — |
  | `craft_sticks` | 2 planks | 4 sticks | — |
  | `craft_wooden_pickaxe` | 3 planks + 2 sticks | `wooden_pickaxe` | table |
  | `craft_stone_pickaxe` | 3 cobblestone + 2 sticks | `stone_pickaxe` | table |
  | `craft_iron_pickaxe` | 3 iron ingots + 2 sticks | `iron_pickaxe` | table |
  | `smelt_iron` | 1 raw iron + 1 coal | 1 iron ingot | furnace |

  Crafting an already-owned pickaxe is a no-op that costs nothing but the tick. **`stick` is a real
  crafted item and a real prerequisite for all three pickaxes, but it is deliberately NOT a scored
  rung** — the coordinator pinned an eleven-rung ladder and this note keeps it at eleven; MineRL's own
  schedule scores `stick` and that difference is recorded in §Sim module → Documented divergences.

An inapplicable primitive is a **no-op that still costs its tick**. There is no error, no repair and
no free retry: that is the whole cost model of the game, and against a hard deadline it is the
game's entire difficulty.

### The eleven milestones — the ObtainDiamond ladder

MineRL's ObtainDiamond ladder, rung for rung, in the canonical order. This ordering is
`milestoneIds` in `results`, the order of the viewer's ladder panel, and the order of the `locked`
list in the observation. Each unlocks **once**, permanently, the tick its predicate over **sim state**
first becomes true, and is never revoked. **No rung is ever a self-report**: the predicate is
evaluated by the engine against the inventory, the tool flags and the placed blocks — that is the
idea's "milestone verification from game state", implemented literally.

| # | id | Points | Unlocks when |
|---|---|---|---|
| 1 | `log` | 1 | `log ≥ 1` |
| 2 | `planks` | 2 | `planks ≥ 1` |
| 3 | `crafting_table` | 4 | a `crafting table` block exists anywhere in the world (the cog placed one) |
| 4 | `wooden_pickaxe` | 8 | `wooden_pickaxe` is owned |
| 5 | `cobblestone` | 16 | `cobblestone ≥ 1` |
| 6 | `stone_pickaxe` | 32 | `stone_pickaxe` is owned |
| 7 | `iron_ore` | 64 | `raw_iron ≥ 1` |
| 8 | `furnace` | 128 | a `furnace` block exists anywhere in the world |
| 9 | `iron_ingot` | 256 | `iron_ingot ≥ 1` |
| 10 | `iron_pickaxe` | 512 | `iron_pickaxe` is owned |
| 11 | `diamond` | 1024 | `diamond ≥ 1` |

They are recorded through the starter's own ledger — `sim.recordMilestone(0, id)`, which is
`recordAchievement` (`src/ctf/roster.nim:640-648`) renamed and otherwise kept verbatim, already
deduplicating — plus a parallel `milestoneTick[11]` array this fork adds beside `earnedAchievements`
so the viewer's timeline knows *when* each rung lit.

### Scoring formula and sign

At the end of the episode:

```
milestoneScore   = sum over unlocked i of 2^i             (0 .. 2047; i = 0..10 in ladder order)
milestonesReached = popcount(milestoneUnlocked)           (0 .. 11)
deepestMilestone  = the LARGEST i with milestoneUnlocked[i], or none
deepestTick       = milestoneTick[deepestMilestone]       (1 .. maxTicks), or 0 if nothing unlocked
speedBonus        = 0 if milestonesReached == 0 else (maxTicks - deepestTick)   (0 .. maxTicks-1)

scores[0] = 1000 * milestoneScore + speedBonus
```

**Sign: higher is better, and every term only ever adds.** `scores[0]` is never negative; the minimum
is `0` (a cog that did nothing) and the maximum is `1000 × 2047 + 959 = 2 047 959`.

`milestoneScore` is literally the **eleven-bit milestone mask read as an integer** — bit `i` is rung
`i` — which is why the ladder is exactly lexicographic: `2^k > 2^0 + … + 2^(k-1)`, so **reaching one
rung higher beats every possible combination of the rungs below it**. A cog that reaches the iron
pickaxe and nothing else outranks a cog that collected every rung up to the iron ingot. That is the
whole point of a milestone ladder and it is stated as an integer identity, not as a convention.

The tie-break is **speed**: `maxTicks` is 960 (`standard`) or 640 (`deepcut`), both `< 1000`, so
`speedBonus` can never reach one rung's worth and is purely a tie-break, and it rewards reaching the
same rung earlier. That is the idea's own "milestone timeline" turned into a number.

**The league ranks by `results.scores[0]`.** With one seat, every episode is a solo run and the
platform's Elo is computed from these per-episode per-seat numbers; a policy climbs by getting deeper,
faster, across more seeds. `results.win[0]` is `milestonesReached >= parMilestones` (a variant
constant: **6** in `standard`, **5** in `deepcut`) — a "did the cog clear the bar" flag, not a duel —
and **`results.winner` is `0` when `win[0]` is true and `null` otherwise** (there is no opponent, so
the only honest winner is the seat itself or nobody).

**Measured but never scored:** `blocksMined`, `blocksPlaced`, `itemsCrafted`, `ironSmelted`,
`shaftsDug`, `bridgesPlaced`, `cellsSeen`, `deepestLevel`, `ticksPerLevel[4]`, `coalMined`,
`ironOreMined`, `diamondsMined`, `interrupts`, `primitivesExecuted`, `actionsDropped`,
`macrosUnreachable`, `repliesRepaired`. All are in `results`, on the endcard and in the feed. Paying
for any of them directly would let a policy farm the metric (mine and re-place the same stone
forever); §Out of scope records the decision.

**Integrity (the idea's note), decided.** "Seeded worlds" is implemented as: the episode `seed` is
randomised by the runner, recorded in the replay and in `results.seed`, and **never appears in any
observation or prompt**. The seat never sees an unexplored cell, a noise-field value, a block on a
level it has not visited, a future draw, its own score, or its own real player name. "Milestone
verification from game state" is the predicate table above, evaluated by the engine every tick.
"Replay verification" is the starter's per-tick `gameHash` chain, re-derived in the browser by the
same sim module (§Server → Determinism).

### Turn and tick structure — the exact resolution order

Per **command turn** `T`, in this order:

1. If the episode has already ended, stop (§End conditions). Otherwise build the seat's observation
   from the current state (§Decisions → observation).
2. Issue the seat's LLM request. There is exactly **one** seat, so this is a batch of one through the
   starter's unchanged `engine.client.curl.makeRequests` path (`src/ctf/decide.nim:427`) — the code is
   the starter's batching code, carrying one request. Attempt-1 deadline `attempt1Ms = 6000`. A
   scripted seat computes locally, instantly, and consumes no request.
3. If the seat timed out, errored, returned non-JSON, or returned no usable `actions` array, it is
   retried **once**, `retryMs = 3000`.
4. Still no usable reply → the **`miner`** scripted plan is computed server-side (the same proc the
   `miner` baseline uses — imported, never duplicated) and a `fallback` record is written.
5. **Validate and expand the plan**, in the order the reply lists it:
   a. Entries past `maxActionsPerTurn = 12` are dropped and counted in `actionsDropped`.
   b. Each entry is validated against the reply schema; an entry that does not validate is
      **dropped** (never rewritten as a different action), counted in `repliesRepaired`, and reported
      back next turn.
   c. Macros are expanded against the **known map as of turn start**: `move` into up to `n` step
      primitives, `mine` / `dig_down` / `climb_up` / `craft_*` / `smelt_iron` / `noop` into up to `n`
      copies of themselves, `tunnel` into `n` × (`mine`, `move_<dir>`) pairs, `goto` into the BFS path
      (§Decisions → the driver). Each macro yields at most `macroPrimitiveCap = 20` primitives. A
      `goto` whose target is not reachable through known walkable cells **on the current level**
      yields **zero** primitives, counts in `macrosUnreachable`, and is reported next turn as
      `unreachable`.
   d. The whole expanded queue is truncated to `turnTicks = 20` primitives; the surplus is discarded
      and `planTruncated` is reported next turn. **Nothing carries over.**
6. `say` (≤ 160 runes) and `notes` (≤ 400 runes) are sanitised on rune boundaries and, with the
   accepted plan, written as the turn's `directive` replay record. `notes` is echoed back to this
   seat next turn and to nobody else; `say` is drawn in the spectator feed.
7. `turnSpacingMs = 2600` is a floor on the wall clock between consecutive request **starts** (the
   starter's mechanism at `src/ctf/decide.nim:384-389`, kept), pinning the steady state at 23 req/min
   against the sidecar's 30/min per-episode cap.

Then, for each of the next `turnTicks` ticks, in this order — **this is the whole physics of the game
and nothing else mutates the world**:

1. `tick += 1`.
2. Pop the next primitive from the queue. If the queue is empty the primitive is **`noop`** (a real
   cost: the tick is spent, and the deadline does not care why).
3. **Apply the primitive** exactly as §The seventeen actions specifies (movement/facing, `mine`,
   `dig_down`, `climb_up`, placing, crafting, smelting), recording `blocksMined`, `blocksPlaced`,
   `itemsCrafted`, `ironSmelted`, `shaftsDug`, `bridgesPlaced`, `coalMined`, `ironOreMined`,
   `diamondsMined`, and emitting the matching event.
4. **Milestones**: evaluate every not-yet-unlocked predicate of §The eleven milestones; a newly true
   one is recorded with `milestoneTick[i] = tick` and emits `milestone`.
5. **Visibility**: mark the `(2r+1) × (2r+1)` window centred on the cog **on its current level** as
   seen, where `r = surfaceViewRadius = 5` at `z = 0` and `r = deepViewRadius = 2` at `z ≥ 1`; if the
   cog's cell has a shaft down, also mark `(x, y, z+1)` seen; if it has a shaft up, also mark
   `(x, y, z−1)` seen. Merge into the four known maps (last-seen block + `seen_tick`) and update the
   region map, `nearest` and `known_ore`.
6. **Death check**: the cog entered `lava` this tick → the episode ends on this tick with
   `endRule = death` and `deathCause = lava`.
7. **Diamond check**: rung 11 (`diamond`) is unlocked → the episode ends immediately with
   `endRule = diamond`. There is nothing left to do and a triumphant early finish should read as one —
   and it maximises `speedBonus`, which is exactly the incentive intended.
8. **Interrupt / stop**: if the episode ended, or if this tick made a **`lava` cell within Chebyshev 1
   of the cog** newly known (whether by the view or by a `dig_down` that broke through onto it),
   **break out of the tick loop** — the remaining primitives of the turn are discarded, `interrupts`
   increments, `last_plan.interrupted` becomes `lava_found`, and the next turn begins.
9. Mix the tick into `gameHash` and append it to the replay's hash chain.

The interrupt rule is the game's only reactivity, and it is the right one: lava is the only thing in
this world that can end a run, so finding some next to you throws away the rest of your plan and makes
you look at where you are standing. Lava further away, and every `blocked` primitive that is not
`lava_below`, costs its tick and nothing more.

### Visibility — the exact rule

The view is the `(2r+1)²` square of cells centred on the cog **on the cog's current level**, in world
orientation (not rotated to the heading — the one an LLM reads without a coordinate transform, since
`move_north` and the row above are then the same direction). `r = 5` at the surface (an **11 × 11**
window: the sky is open) and `r = 2` underground (a **5 × 5** window: it is dark down there and you
see the walls of your own tunnel). Cells outside the grid cannot occur, because the bedrock ring is
inside the world. The cog's own cell reads `@`; a cell with a shaft reads `v` or `^`; otherwise the
block glyph.

**There is no occlusion and no line-of-sight**: everything in the box is visible. That keeps the sim
integer, fast and hash-stable, and the depth-dependent radius already does the work a light model
would.

The **known map** is four 32 × 32 arrays of last-observed block plus the tick it was last observed. A
cell never in a view stays `?` forever, on every level. **A level the cog has never descended to is
entirely `?`** — this is the single most important fact about the game's difficulty: the diamonds are
under a floor you cannot see through. A cell observed and left behind keeps its last observed block,
which is always still true here (nothing but the cog changes the world), so `seen_tick` is reported
for honesty rather than for staleness.

### Variants

Both are `num_agents: 1`, `levelCount: 4`, `levelSize: 32`, `turnTicks: 20`.

| Variant | `maxTurns` | `maxTicks` | lava ‰ (`z2`/`z3`) | coal ‰ (`z1`/`z2`) | iron ‰ (`z2`/`z3`) | diamond ‰ (`z3`) | `parMilestones` |
|---|---|---|---|---|---|---|---|
| `standard` | 48 | 960 | 12 / 30 | 180 / 80 | 140 / 110 | 70 | 6 |
| `deepcut` | 32 | 640 | 18 / 45 | 270 / 120 | 210 / 165 | 105 | 5 |

`standard` is the ObtainDiamond run: 960 ticks, which is roughly three times a perfect line through
the ladder (§ the arithmetic below), so the game is about planning and navigation rather than about
executing a known optimum. `deepcut` is the same ladder against **two thirds of the clock** with
**half again as much ore and half again as much lava** — the deadline variant the idea's "long-horizon
milestone" asks for, where a policy that wastes six turns walking back to the surface simply does not
finish. Nothing else differs: the ladder, the recipes, the tiers, the action set and the level
structure are identical, so the two variants are directly comparable and `milestoneScore` means the
same thing in both.

**The tick arithmetic, out loud.** A perfect line through the ladder costs roughly: 10 ticks walking to
a tree + 2 `mine` (6 logs) + 3 `craft_planks` + 2 `craft_sticks` + 1 `place_crafting_table` + 1
`craft_wooden_pickaxe` ≈ **19 ticks** for rungs 1–4; 1 `dig_down` (rung 5, the floor under spawn is
forced stone) ≈ **20**; ~22 ticks tunnelling on `z=1` for 12 cobblestone and 3 coal, + 1 table + 1
`craft_stone_pickaxe` ≈ **45**; 1 `dig_down` + ~40 ticks tunnelling on `z=2` for 3 iron ore, + furnace
+ table + 3 `smelt_iron` + 1 `craft_iron_pickaxe` ≈ **95**; 1 `dig_down` + ~60 ticks of lattice
tunnelling on `z=3` to find a diamond vein ≈ **160 ticks**. `standard`'s 960 ticks is therefore ~6×
the perfect line and ~3× a competent one, and `deepcut`'s 640 is ~4× — tight enough that route
choice decides the run, loose enough that the diamond is genuinely reachable. `tests/test_minecraft_
sim.nim` asserts the `miner` baseline reaches at least rung 9 on the majority of `standard` seeds and
the diamond on some.

### End conditions and legal `results.reason` values

The episode ends at the first of: **the diamond**, **death in lava**, the **turn cap**, the **tick
cap**, or the **wall-clock stop**.

- **Diamond** — rung 11 unlocked, at tick step 7. Settles immediately. `endRule = diamond`.
- **Death** — the cog entered `lava`, at tick step 6. Settles immediately. `endRule = death`,
  `deathCause = "lava"`.
- **Turn cap** — `turnsPlayed == maxTurns` (48 / 32). `endRule = turnCap`. **This is the in-game
  deadline and the normal way a run ends.**
- **Tick cap** — `tick == maxTicks` (960 / 640). `endRule = tickCap`. Reachable only if no turn ever
  interrupted, in which case it coincides with the turn cap; it is kept as an independent guard so no
  arithmetic error can produce an unbounded loop.
- **Wall-clock stop** — the engine's `wallClockBudgetSeconds` guard, the starter's check at
  `src/ctf/server.nim:1407-1417`, kept. `endRule = wallClock`.
- **Fault** — an unrecoverable server-side error. `endRule = fault`.

`results.reason` is the starter's closed enum; **exactly these three values are legal** and the game
emits nothing else:

- **`complete`** — the episode finished on its own terms: `diamond`, `death`, `turnCap` or `tickCap`.
  The healthy value, and the one phase 60 check 4 requires. **Running out of ticks is `complete`, not
  a failure**: stopping at the iron pickaxe with the clock at zero is the game working exactly as
  designed, and so is stepping into lava on tick 300.
- **`deadline`** — the **wall-clock** stop fired (`endRule = wallClock`). This is the *real-time*
  deadline, not the in-game one; everything unlocked so far still scores and the results document is
  complete. **Declared acceptable** by this design note for phase 60 check 4, but it should be
  unreachable in practice: the budget guard (§Decisions) drops the seat to scripted play two turns
  before the stop, and scripted turns cost microseconds.
- **`fault`** — `endRule = fault`. Always a defect; CI asserts it never occurs on the fixture seeds.

`endRule` is its own closed enum — `diamond | death | turnCap | tickCap | wallClock | fault` —
declared in the manifest's `results_schema` and asserted by `tests/test_minecraft_engine.nim`.

---

## Decisions: LLM with scripted fallback

**Both champions are LLM prompt policies; both fillers are scripted baselines; one image, switched by
env.** `PLAYER_PROMPT=<strategy text>` makes the seat an LLM seat. `PLAYER_SCRIPTED=<name>` with
`name ∈ {miner, scrounger}` makes it a scripted seat. A seat that sets neither is
`PLAYER_SCRIPTED=miner` (the starter's "anything unrecognised is the published default" rule,
`src/ctf/baselines.nim`). **A scripted policy seated as a champion is a failure state.**

### Where the decision happens

**In the game server, not the player container** — the starter already works this way
(`src/ctf/decide.nim` + `src/ctf/llm.nim`), and it is the only shape that works on this platform: the
`anthropic_api_key` coworld secret is injected into the **game** pod
(`game.runnable.env.ANTHROPIC_API_KEY_URI = secret://coworld/minecraft/anthropic_api_key` — the hive
2026-08-23 gotcha), phase 60 greps the **game** log for `falling back` / `LLM provider is
unavailable`, and `docker_smoke.sh` forwards `ANTHROPIC_API_KEY` to the game container only. No
`USE_BEDROCK` flag is needed on the policies, because the player pod makes no LLM call.

`src/minecraft_player.nim` is `src/paintball_player.nim` forked with no behaviour change: read
`COWORLD_PLAYER_WS_URL` (legacy alias `COGAMES_ENGINE_WS_URL`), dial with bounded retries, send — and
**re-send for the first ~10 s of received frames** (the paintball 2026-08-25 slot-sequential-join
scar) — the registration blob

```json
{"policy":"<label>","prompt":"<PLAYER_PROMPT or empty>","scripted":"miner"|"scrounger"|null}
```

with `prompt` rune-truncated at **`MaxPromptRunes` = 4000** and `policy` at 64 runes, then acknowledge
frames until the socket closes, **exiting 0 on a dead socket** (the raid 0.1.3 close-frame race:
whisky's `receiveMessage` raises on a close frame and mummy's `send` only queues).

`src/minecraft/llm.nim` is `src/ctf/llm.nim`, forked with no behaviour change:

- Credentials in order: **Bedrock sidecar** (`AWS_ENDPOINT_URL_BEDROCK_RUNTIME` +
  `AWS_BEARER_TOKEN_BEDROCK`, region from `AWS_REGION` / `AWS_DEFAULT_REGION`, default `us-west-2`) →
  `ANTHROPIC_API_KEY` → `ANTHROPIC_API_KEY_URI` (via `readCogameUri`) → **none**, in which case the
  client is `disabled = true` and every turn falls back instantly with no network wait, so offline
  certification finishes in seconds.
- Bedrock model candidates in order, `BEDROCK_MODEL` pins one:
  `us.anthropic.claude-haiku-4-5-20251001-v1:0`, then `us.anthropic.claude-sonnet-4-5-20250929-v1:0`;
  `tryNextBedrockModel` on 401/403 "Model access is denied" and on 429.
  **`us.anthropic.claude-sonnet-4-6` is deliberately not a candidate** (it times out on every sidecar
  call — raid round 2, 2026-08-23).
- `maxOutputTokens = 900` (not 400 — "cut off at max_tokens"). **No `output_config.effort`** when the
  model string contains `haiku` or `4-5`. Bedrock bodies carry
  `anthropic_version: "bedrock-2023-05-31"`.
- A system prompt demanding the reply **begins with `{`**, **plus the assistant-turn prefill of `{`**
  (both Anthropic Messages and Bedrock invoke accept it), the prefill re-prefixed before parsing and
  guarded against a provider that echoes it (the procgen 0.1.2 `cut off at max_tokens` scar — the fix
  is the prefill, never a bigger cap).
- `extractJsonObject` (`src/ctf/directives.nim` — outermost balanced `{…}`, fence-tolerant, tolerant
  of trailing prose) and `truncateRunes` / `sanitizeSay` / `sanitizeNote` unchanged.

### Cadence, the per-turn call budget, and the wall-clock arithmetic

One command turn every ≤ 20 ticks; **at most 48 turns per episode** (`standard`; 32 in `deepcut`).
**The per-turn LLM call budget for the single seat is exactly ONE request, plus at most ONE retry** —
there is a single seat, so the starter's one-parallel-batch-per-turn machinery
(`src/ctf/decide.nim:427`) carries a batch of one and is otherwise untouched. **At most `48 × 2 = 96`
provider calls per episode** (`deepcut`: 64), and never more than one in flight.

```
attempt1Ms                          6.0 s   (whole seconds - sim_config.nim:696-706 rejects otherwise)
retryMs                             3.0 s   (whole seconds; attempt1Ms + retryMs <= turnBudgetMs - :691)
turnBudgetMs                        9.5 s   (monotonic deadline around the whole turn)
turnSpacingMs                       2.6 s   -> 1 seat x 60/2.6 = 23 req/min  (sidecar cap: 30)

48 turns x max(spacing 2.6 s, latency ~3.4 s)  typical            = 163 s
48 turns x turnBudgetMs 9.5 s, absolute worst                     = 456 s
960 ticks over 4 x 32x32 integer grids, Nim, fastMode             =   1 s
lobby / connect wait (lobbyJoinTimeoutTicks 2400 = 100 s at       =  15 s   (cap: 100 s)
   TargetFps 24; typical 15 s)
gameOverTicks hold + results + replay write (retried uploader)     =  20 s
                                                                  -------
typical total                                                     = 199 s   < 720 s
absolute worst case (456 + 1 + 100 + 20)                          = 577 s   < 660 s stop
engine hard stop wallClockBudgetSeconds                           = 660 s   -> reason "deadline"
platform kill (episodeTimeoutSeconds)                             = 1200 s
```

**720 s is 60 % of the assumed 1200 s `episodeTimeoutSeconds`**; every shipped variant's
`wallClockBudgetSeconds` is ≤ 660 and `tests/test_minecraft_manifest.nim` asserts it. The typical
figure is conservative: a cog that finds a diamond on turn 30 plays fewer than 48 turns, and `deepcut`
is two thirds of every line above.

**Rate guard.** `turnSpacingMs` pins the steady state at 23 req/min, but a run of retrying turns
issues two requests each. The engine therefore keeps a **rolling 60 s request counter**: if issuing the
next request would push the trailing-60 s count above **28**, that turn skips the call and takes the
`miner` plan with `cause = "rate_guard"`. Bounded, logged, never a sleep on the episode's critical
path (the raid round 2 sidecar-throttle scar).

`fastMode: true` in every variant, as in the starter's paintball variant: the seat sends no per-tick
inputs (the server computes every primitive), so the Sprite v1 Ready packet's dead-reckoning hazard
cannot arise.

### Degrade, never hang

Every wait is bounded: the two request deadlines, the outer `turnBudgetMs`, the rate guard,
`lobbyJoinTimeoutTicks`, mummy's socket timeouts on the serve thread (which runs independently of the
game loop, so a 9.5 s LLM stall cannot drop a connection or stall `/healthz`), the 660 s engine stop,
and ctf's `gameOverTicks` hold before exit — kept so `/healthz` and `/global` keep answering for a
bounded grace after artifacts are written (the lantern 0.1.3 `/global` ping scar).

On the seat's timeout or parse failure: **retry once**; on the second failure that turn's plan becomes
the **`miner`** scripted plan computed inside the game (the same proc the `miner` baseline uses —
imported, never duplicated), and a `fallback` record is written with
`cause ∈ {timeout, parse_error, transport_error, no_credentials, rate_guard, budget_guard,
disconnected}`. `results.fallbackTurns` counts them. The attempt-1 notice says **`will retry`**; only
a genuine second failure logs **`falling back`** (the pommerman 0.1.1 phase-60 grep scar; the
starter's two phrasings live at `src/ctf/decide.nim:463` and `:491`).

**No failure mode leaves the cog without an action.** The tick loop always has a primitive: the turn's
queue, else `noop`, which is a legal state that costs a tick and nothing else. A seat that never
connects is reported once to `COGAME_PLAYER_FAILURE_URI` with the platform's **closed** payload —
exactly `{"message", "failed_policy_index"}`, nothing else — and the episode plays out scripted.

**The episode settles early rather than overrunning**: the diamond ends it on the tick it is cut,
death ends it on the tick it happens, the turn cap ends it deterministically, and the budget guard
(`src/ctf/decide.nim:328-346`, kept) switches the LLM off for the rest of the episode the moment two
more full turns would not fit inside `wallClockBudgetSeconds`, so the episode ends `complete`, not
`deadline`.

### Per-seat observation: exactly what is visible and what is hidden

The guiding line: **the cog knows what it is carrying, what it has already done, and exactly what it
has looked at — and nothing about a floor it has not cut through.**

**Visible.**

- **The rules of the world, once, at registration** — `levelCount` 4 and their y-labels, `levelSize`
  32, the two view radii, the glyph legend, the seventeen actions and what each does, the eight
  recipes and their costs, the four pickaxe tiers and what each can mine, `turnTicks`,
  `maxActionsPerTurn`, the fact that lava kills instantly on a step but not on a `dig_down`, and the
  fact that finding lava next to you ends the turn. Static; afterwards referred to by id.
- **The egocentric window**, `view` — 11 strings of 11 glyphs at the surface, 5 strings of 5
  underground, world-oriented, cog at the centre reading `@`. This is what the viewer's inset draws.
- **A 16 × 16 region map of the CURRENT LEVEL ONLY**, `region` — that level's 32 × 32 known map
  downsampled 2 × 2, each region showing the single most *notable* block it is known to contain, by
  the priority `D > i > c > ! > T > ~ > t > f > v > ^ > = > # > , > . > B > ?`. Sixteen strings of
  sixteen glyphs: 272 characters instead of the 1056 a full level map would cost every turn. **The
  other three levels are not in `region`** — the cog gets one floor at a time, which is the game.
- **`nearest`** — a fixed dictionary of the closest **known** cell **on the current level** of each of
  `tree`, `water`, `stone`, `coal_ore`, `iron_ore`, `diamond_ore`, `lava`, `crafting_table`,
  `furnace`, `tunnel`, `shaft_down`, `shaft_up`; each `{x, y, d}` with `d` the Chebyshev distance, or
  `null` if never seen. This is what makes `goto` usable and it is the single most load-bearing field
  in the observation.
- **`known_ore`** — up to **24** known ore cells **across all four levels**, each
  `{what, z, x, y, d, seen_tick}` (`d` is the Chebyshev distance if `z` is the cog's level, otherwise
  `null`), sorted ascending by `z`, then `d` (nulls last), then `(y, x)`. This is the cog's long-term
  memory of the mine, and it is what lets it write "there is iron at z=2 (9,21)" and come back with
  the right pickaxe.
- **`column`** — for each of the four levels, `{z, label, visited, shaft_here}`: whether the cog has
  ever stood on that level, and whether *this exact (x, y)* has a shaft connecting downward. It is how
  the cog knows it can `climb_up` without guessing.
- **The cog's own state** — `x`, `y`, `z`, `level_label`, `facing`, the eight inventory counts, the
  three tool booleans, `tier`, `near.table` / `near.furnace`, `ahead` (the glyph, the name and the
  coordinates of the cell it faces, plus `mineable_by_you: true|false`), and `below` (the block at
  `(x, y, z+1)` if it has ever been seen, else `{"known": false}`).
- **Time** — `tick`, `ticks_left`, `turn`, `turns_left`. The deadline is never hidden; it is the whole
  pressure.
- **Its own milestone state** — `milestones.unlocked` (ids in ladder order, each with the tick it lit
  and its point value), `milestones.locked` (the rest, in order, so the model knows what is next),
  `count`, `of`, and `next` (the id of the lowest locked rung).
- **Its own last turn** — `last_plan.executed` (the primitives that actually ran), `truncated`,
  `dropped`, `unreachable`, `blocked` (a list of `{act, why}`), `interrupted` (`""` or `lava_found`),
  and `notes` echoed back.

**Hidden.** The episode **seed**; every cell never observed, on every level; **every block on a level
the cog has not descended to**; every noise-field value and every generator threshold; every future
draw; the cog's own **score**; `parMilestones`; and its own real player/policy name. Nothing about
identity ever reaches a prompt.

The observation is a JSON object appended to the user message, and is mirrored (minus `notes`) into
the replay's `directive` record, so the replay explains every decision.

```json
{
  "you": "Alpha",
  "turn": 21, "tick": 401, "ticks_left": 559, "turns_left": 27,
  "world": {"levels": 4, "size": 32, "view": 5, "region": 16,
            "level_labels": ["y=64 (surface)", "y=48 (stone)",
                             "y=32 (iron depth)", "y=12 (diamond depth)"],
            "legend": {".": "grass", ",": "sand", "~": "water", "T": "oak tree",
                       "#": "stone", "c": "coal ore", "i": "iron ore",
                       "D": "diamond ore", "=": "tunnel", "!": "LAVA (a step into it kills you)",
                       "B": "bedrock", "t": "crafting table", "f": "furnace",
                       "v": "shaft DOWN from here", "^": "shaft UP from here",
                       "@": "you", "?": "never seen"}},
  "agent": {"x": 12, "y": 19, "z": 2, "level_label": "y=32 (iron depth)",
            "facing": "east", "tier": 2,
            "ahead": {"glyph": "i", "what": "iron ore", "x": 13, "y": 19,
                      "mineable_by_you": true},
            "below": {"known": false}},
  "inventory": {"log": 1, "planks": 5, "stick": 4, "cobblestone": 14,
                "coal": 3, "raw_iron": 0, "iron_ingot": 0, "diamond": 0},
  "tools": {"wooden_pickaxe": true, "stone_pickaxe": true, "iron_pickaxe": false},
  "near": {"table": true, "furnace": false},
  "view": ["#####",
           "#=c##",
           "#@i##",
           "#==t#",
           "###!#"],
  "region": ["????????????????",
             "????????????????",
             "??????##????????",
             "?????#==#???????",
             "?????#@i#???????",
             "?????#=t#???????",
             "??????#!????????",
             "????????????????",
             "????????????????",
             "????????????????",
             "????????????????",
             "????????????????",
             "????????????????",
             "????????????????",
             "????????????????",
             "????????????????"],
  "nearest": {"tree": null, "water": null, "stone": {"x": 12, "y": 18, "d": 1},
              "coal_ore": {"x": 13, "y": 18, "d": 1},
              "iron_ore": {"x": 13, "y": 19, "d": 1},
              "diamond_ore": null, "lava": {"x": 15, "y": 21, "d": 3},
              "crafting_table": {"x": 13, "y": 20, "d": 1}, "furnace": null,
              "tunnel": {"x": 12, "y": 20, "d": 1},
              "shaft_down": null, "shaft_up": {"x": 11, "y": 16, "d": 3}},
  "known_ore": [{"what": "coal_ore", "z": 1, "x": 20, "y": 7, "d": null, "seen_tick": 190},
                {"what": "iron_ore", "z": 2, "x": 13, "y": 19, "d": 1, "seen_tick": 401},
                {"what": "coal_ore", "z": 2, "x": 13, "y": 18, "d": 1, "seen_tick": 401}],
  "column": [{"z": 0, "label": "y=64 (surface)", "visited": true, "shaft_here": false},
             {"z": 1, "label": "y=48 (stone)", "visited": true, "shaft_here": false},
             {"z": 2, "label": "y=32 (iron depth)", "visited": true, "shaft_here": false},
             {"z": 3, "label": "y=12 (diamond depth)", "visited": false, "shaft_here": false}],
  "milestones": {"count": 6, "of": 11, "next": "iron_ore",
                 "unlocked": [{"id": "log", "tick": 14, "points": 1},
                              {"id": "planks", "tick": 17, "points": 2},
                              {"id": "crafting_table", "tick": 19, "points": 4},
                              {"id": "wooden_pickaxe", "tick": 20, "points": 8},
                              {"id": "cobblestone", "tick": 21, "points": 16},
                              {"id": "stone_pickaxe", "tick": 96, "points": 32}],
                 "locked": ["iron_ore", "furnace", "iron_ingot", "iron_pickaxe", "diamond"]},
  "last_plan": {"executed": ["mine", "move_east", "mine", "move_east", "mine"],
                "truncated": false, "dropped": 0, "unreachable": 0,
                "blocked": [{"act": "mine", "why": "unmineable"}],
                "interrupted": ""},
  "notes": "z=2 workshop: table (13,20). need 8 cobble for a furnace, have 14. iron at (13,19). coal seam z=1 (20,7) if I run short. lava SE around (15,21) - stay north of row 20."
}
```

Reading it: the cog is on the iron level facing an iron ore block it can mine, one cell from the table
it placed itself, three cells from lava, six rungs up the ladder with five to go and 559 ticks left.

Field rules. `view` is always `2r+1` strings of `2r+1` characters for the current level's `r`;
`region` is always **16 strings of 16 characters**; `nearest` always has all twelve keys (value or
`null`); `column` always has exactly four entries; the array shapes never change. Glyphs are exactly
the closed set in the legend. `agent.facing` is one of `north|east|south|west`. `known_ore` is at most
24 entries. `last_plan.executed` lists the **primitives** that actually ran — macros already expanded
— so the seat can see a `tunnel` get cut off rather than guess.

### Reply schema and per-field caps

```json
{"actions": [{"act": "mine", "n": 1},
             {"act": "goto", "x": 13, "y": 20},
             {"act": "place_furnace"},
             {"act": "smelt_iron", "n": 2},
             {"act": "tunnel", "dir": "east", "n": 6}],
 "say": "iron in the wall and a table already down - furnace here, smelt two, then straight east",
 "notes": "z=2 workshop (13,20). furnace next to it. lava (15,21). after 3 ingots: iron pick, dig_down."}
```

| Field | Type | Cap / domain |
|---|---|---|
| `actions` | array | **≤ 12 entries** (`maxActionsPerTurn`). Entries past the cap are dropped and counted in `actionsDropped`. Absent or empty = the turn is 20 `noop` ticks, and the reply is still **usable** |
| `actions[].act` | string | **≤ 24 runes**; enum = the **17 primitives** by name (`noop`, `move_north`, `move_east`, `move_south`, `move_west`, `mine`, `dig_down`, `climb_up`, `place_block`, `place_crafting_table`, `place_furnace`, `craft_planks`, `craft_sticks`, `craft_wooden_pickaxe`, `craft_stone_pickaxe`, `craft_iron_pickaxe`, `smelt_iron`) **plus 3 macros** (`goto`, `move`, `tunnel`), lower-cased and `-`→`_` normalised before matching |
| `actions[].x`, `.y` | integer | required iff `act == "goto"`; **clamped to 0 … 31**; a non-integer or absent value **drops the entry** and counts in `repliesRepaired` |
| `actions[].dir` | string | required iff `act ∈ {move, tunnel}`; **≤ 6 runes**; matched case-insensitively against `north`, `east`, `south`, `west`, `n`, `e`, `s`, `w`, `up`, `down`, `left`, `right` (`up`→north, `down`→south, `left`→west, `right`→east); anything else drops the entry |
| `actions[].n` | integer | honoured **only** on `move` (1 … 12), `tunnel` (1 … 10), `mine` (1 … 12), `dig_down` (1 … 3), `climb_up` (1 … 3), `craft_planks` (1 … 8), `craft_sticks` (1 … 4), `smelt_iron` (1 … 6) and `noop` (1 … 20); clamped into range; absent = 1; ignored on every other verb |
| `say` | string | **≤ 160 runes** (`MaxSayRunes`) — the cog thinking out loud; drawn in the spectator feed and in the replay, never fed back to the seat |
| `notes` | string | **≤ 400 runes** (`MaxNoteRunes`) — private scratchpad, echoed to this seat only next turn |
| whole reply | bytes | **≤ 4096** read from the provider before parsing |
| `PLAYER_PROMPT` | string | **≤ 4000 runes** (`MaxPromptRunes`) at registration |

`MaxSayRunes` and `MaxNoteRunes` are **re-pinned in this fork**: the starter has
`MaxSayRunes = ShoutMaxChars = 10` and `MaxNoteRunes = 160` (`src/ctf/sim_types.nim:747, 794-795`),
which are a 10-character in-world shout and a short note. A cog narrating a descent needs a sentence,
and a cog carrying the coordinates of four levels of ore between turns needs more than 160 runes, so
`MaxSayRunes = 160` and `MaxNoteRunes = 400` here, and `ShoutMaxChars` is deleted with the shout
mechanic (§Sim module → Deleted).

**Every string that lands in the replay — `say`, `notes`, the policy label, `stopDetail`, recorded
error text — is truncated on RUNE boundaries** via the starter's `truncateRunes` / `runeSubStr`, never
by byte index. Byte truncation is what makes a replay that renders in a browser fail a strict UTF-8
parser; `tests/test_minecraft_replay.nim` asserts it with 4-byte emoji sitting exactly on every cap.

Unknown top-level and per-action keys are ignored. A reply with a valid `say` but no `actions` is
**usable** (the turn is spent idling and the narration is delivered). A reply that is not a JSON object
is a parse failure. **Invalid actions are dropped, never rewritten**: turning a malformed `goto` into a
`move_south` could walk the cog into lava on the game's own initiative, so the entry is removed,
counted in `repliesRepaired`, and reported back as `dropped` next turn.

### System prompt (fixed, identical for both champions)

```
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
```

### Champion #1 — `minecraft-obtaindiamond` (owner **daveey**), `PLAYER_PROMPT`

```
Get to the diamond. Nothing else is worth a tick.
"milestones.locked" is your to-do list and it is already in dependency order.
Every turn, work the FIRST locked rung you could move on this turn, and fill all
20 ticks with that one job. Never spend a turn "getting ready".
The opening is fixed. Do not improvise it.
  turn 1: goto the nearest T, mine n=2 (that is 6 logs), craft_planks n=3,
          craft_sticks n=1, place_crafting_table, craft_wooden_pickaxe.
          That is four rungs in one turn.
  turn 2: craft_planks with any log left so you carry 8+ planks and 4+ sticks,
          then dig_down and start tunnelling. The floor under your spawn is
          always stone, so that dig_down is also the cobblestone rung.
Rules of the descent, in order of how much they cost you when broken:
1. NEVER walk back up. Wood is the only thing that does not exist below y=64,
   so leave the surface carrying 8 planks and 4 sticks and never need it again.
2. Leave y=48 only with 12+ cobblestone and 3+ coal AND a stone pickaxe. Twelve
   cobblestone is a furnace (8) plus a stone pickaxe (3) plus one spare.
3. The instant a level has nothing left you need, dig_down. A level you have
   finished is a level you should not be standing on.
4. Underground you see 5x5. Tunnel in STRAIGHT LINES:
   {"act":"tunnel","dir":"east","n":9} is 18 ticks and reveals a whole
   corridor. Turn 90 degrees on the next turn so you sweep a lattice instead of
   drilling one hole.
5. The moment "known_ore" lists ore you have the tier for on THIS level, goto it
   and mine it. Ore you cannot mine yet: write its z,x,y into "notes" and come
   back with the right pickaxe.
6. Build the workshop where you are standing. At y=32 with 3 raw iron and 3
   coal: place_crafting_table, place_furnace, smelt_iron n=3,
   craft_iron_pickaxe. Four actions, one turn, no walking.
7. At y=12, tunnel east-west along one row for 9, then next turn move 3 rows
   and tunnel back. Diamond sits in veins of 1-3 blocks; a lattice finds them
   and a random walk does not.
Never step onto "!". If a turn comes back with "interrupted":"lava_found",
lava is adjacent to you: move away from it or place_block into it before you
plan anything else.
Rewrite "notes" every turn: the rung you are on, what you are carrying, the
z,x,y of every ore you have seen and not mined, where your table and furnace
are, and which rows you have already swept.
```

### Champion #2 — `minecraft-branchminer` (owner **daveey-1**, `"player": "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"`), `PLAYER_PROMPT`

```
Mine like an engineer. The ladder falls out of good tunnels.
PHASE 1 - KIT (turns 1-3). Nearest T, mine n=2, craft_planks n=3, craft_sticks
n=2, place_crafting_table, craft_wooden_pickaxe. Then chop a SECOND tree if one
is within 6 cells: 12 planks and 8 sticks is your entire wood budget for the
whole run, and there is no wood underground.
PHASE 2 - THE STAIRCASE. dig_down. On each new level, mine 12 cobblestone
before anything else - two {"act":"tunnel","dir":...,"n":6} turns do it. Twelve
cobblestone is a furnace plus a stone pickaxe plus a spare. Place a table and
craft the stone pickaxe the moment you have 3 cobblestone and 2 sticks.
PHASE 3 - BRANCH MINING, the real technique, and the whole reason to pick me:
  cut a main corridor with {"act":"tunnel","dir":"east","n":9};
  next turn step 3 rows north or south and cut a parallel one back.
  A 5x5 view with 3-row spacing sees every cell in the block. Never dig a
  diagonal, never wander, never re-cut a corridor you already cut. If "region"
  shows "?" to one side, that is the side you sweep next.
PHASE 4 - IRON. At y=32 you want 3 iron ore and 3 coal. Then build the workshop
where you stand: place_crafting_table, place_furnace, smelt_iron n=3,
craft_iron_pickaxe. Materials travel free; you do not.
PHASE 5 - y=12. Same branch pattern, and read "known_ore" every single turn.
One "D" is worth more than everything you have done put together: drop whatever
you are doing, goto it, mine it, and the run ends there in triumph.
SAFETY. Lava is the only thing that can kill you and it only kills you if you
walk into it. When "nearest.lava" has d<=2, either place_block into it or
tunnel the other way - do not path past it. Digging down onto lava is free and
costs only the turn, so never fear a dig_down.
CLOCK. Look at "ticks_left" every turn. Under 200 ticks left, stop exploring and
spend every remaining tick on the cheapest locked rung you can still reach.
"notes": the corridor you are cutting, the rows already swept, table and furnace
z,x,y, and every unmined ore with its z,x,y.
```

### The driver (deterministic, shared by every policy)

`src/minecraft/driver.nim` — the starter's `src/ctf/control.nim` (directive → per-tick actuation),
retargeted from pixel steering to a **primitive queue**. It is the **only** producer of primitives,
and it contains no randomness.

| Action | Expands to |
|---|---|
| any of the 17 primitives | itself, once — or `n` times where §Reply schema allows `n` |
| `move dir n` | up to `n` copies of `move_<dir>` |
| `tunnel dir n` | `n` × (`mine`, `move_<dir>`) in that order — 2 primitives per cell |
| `goto x y` | the `move_<dir>` primitives that walk the BFS path below |

**The `goto` BFS**, run against the **known map of the cog's current level as of turn start**:

- Nodes are cells of that level; edges are 4-adjacency in the fixed order **north, east, south,
  west**.
- A cell is **traversable** iff its known block is `grass`, `sand` or `tunnel`. `?`, `water`, `lava`,
  `stone`, `oak tree`, `coal ore`, `iron ore`, `diamond ore`, `bedrock`, `crafting table` and
  `furnace` are **not** traversable — in particular the driver **never** routes through lava and
  **never** routes through the unknown.
- `goto` never changes `z`. Changing level is `dig_down` / `climb_up` and nothing else.
- Breadth-first from the cog's cell; ties broken by the neighbour order above, so the path is unique
  for a given known map.
- If the **target** is traversable, the path ends **on** it. If the target is not traversable but is
  4-adjacent to some reached cell, the path ends on the nearest such cell and a final `move_<dir>`
  toward the target is appended — which turns the cog to face it without moving (the target is not
  walkable), leaving it exactly positioned for `mine`. If neither, the macro yields **zero**
  primitives and counts as `unreachable`.
- Bounded by `macroPrimitiveCap = 20` primitives; the whole turn's queue is then truncated to
  `turnTicks = 20`.

The driver never invents an action the schema does not express and never produces a step into a cell
it believes is lava — but it makes no promise about a cell the cog has never seen, which is why
walking into the unknown costs an explicit `move` or `tunnel`.

### Scripted baselines (both shipped as league fillers; `miner` is also the server-side fallback)

`src/minecraft/baselines.nim`, the starter's module retargeted. Both emit the **same** reply objects
an LLM does, through the same validator, which is what makes the bounded-orders test meaningful.
Neither ever emits `say` or `notes` — a baseline that narrated would make the feed lie about which
seats are LLMs.

**`miner`** — `PLAYER_SCRIPTED=miner`, and the fallback. A deterministic priority ladder. Every turn,
the **first** matching rule wins and emits at most 12 actions:

1. **Lava adjacent.** `nearest.lava` exists with `d <= 1`. If the cog faces it and
   `cobblestone >= 1`: `{"act":"place_block"}`. Else `{"act":"move","dir":d}` toward the known
   traversable neighbour that maximises the Chebyshev distance to every known lava cell on this level
   (ties by the neighbour order north/east/south/west), then `{"act":"move","dir":d,"n":2}`.
2. **Craft whatever is affordable right now**, in ladder order, first match, emitting that one action
   and then falling through to rule 6 to fill the turn:
   `log >= 1 and planks < 8` → `{"act":"craft_planks","n":min(3, log)}`;
   `planks >= 2 and stick < 4` → `{"act":"craft_sticks"}`;
   `not near.table and planks >= 4 and (a pickaxe recipe is otherwise affordable)` →
   `{"act":"place_crafting_table"}`;
   `near.table and not wooden_pickaxe and planks >= 3 and stick >= 2` → `craft_wooden_pickaxe`;
   `near.table and not stone_pickaxe and cobblestone >= 3 and stick >= 2` → `craft_stone_pickaxe`;
   `cobblestone >= 8 and no furnace placed and raw_iron >= 1` → `place_furnace`;
   `near.furnace and raw_iron >= 1 and coal >= 1 and iron_ingot < 3` →
   `{"act":"smelt_iron","n":min(3, raw_iron, coal)}`;
   `near.table and not iron_pickaxe and iron_ingot >= 3 and stick >= 2` → `craft_iron_pickaxe`.
3. **Wood.** `z == 0 and log < 2 and nearest.tree != null` → `goto` it, `{"act":"mine","n":2}`.
4. **Target ore.** The highest-value known ore **on this level** the cog has the tier for (diamond >
   iron > coal), nearest first, ties by `(y, x)` → `goto` it, `{"act":"mine","n":2}`.
5. **Descend.** `z < 3` and the cog has met this level's exit condition —
   `z=0`: `wooden_pickaxe and planks >= 8 and stick >= 4`;
   `z=1`: `stone_pickaxe and cobblestone >= 12 and coal >= 3`;
   `z=2`: `iron_pickaxe` —
   → `{"act":"dig_down"}` then `{"act":"tunnel","dir":<sweep>,"n":6}`.
6. **Sweep.** `{"act":"tunnel","dir":<sweep>,"n":9}`, where `<sweep>` starts `east` and rotates
   `east → south → west → north` whenever the previous turn's tunnel was blocked by bedrock or the cog
   has swept `sweepTurns = 3` turns in the current direction; on a level where the cog has already
   swept a row, the sweep first emits `{"act":"move","dir":<perpendicular>,"n":3}` so the corridors
   form a 3-row lattice rather than one hole.

`miner` never routes through lava (lava is not traversable to the BFS), never digs down without the
tier the level below needs (rule 5's exit conditions guarantee it), and never walks back up a shaft —
which is exactly the floor a champion has to beat. Like the starter's `DefaultBaselineParams`
(`src/ctf/baselines.nim:38`), its tunables (the wood budget `8/4`, the stone budget `12/3`, the sweep
length `9`, `sweepTurns = 3`, the lattice spacing `3`, and whether ore targeting breaks ties by
distance or by value first) are a parameter object chosen by `tools/tune_baselines.nim`'s sweep, not
guessed; `tools/ci/baseline_tuning.json` records the sweep's pick and
`tests/test_minecraft_tuning.nim` asserts the shipped defaults still equal it.

**`scrounger`** — `PLAYER_SCRIPTED=scrounger`. The reactive control: no memory, no BFS, no ore
targeting. Every turn it emits, in this order: (a) the **single** first recipe in ladder order that is
affordable from inventory and current adjacency *right now* (the same test as `miner` rule 2, with no
lookahead and no table placement unless `planks >= 4` and it is standing next to nothing); (b) if
`tier >= 1` and `tick mod 120 < 20`, `{"act":"dig_down"}`; (c) the rest of the twelve slots filled by
alternating `{"act":"mine","n":2}` and `{"act":"move","dir":<facing>,"n":1}`, rotating `facing`
clockwise (`north → east → south → west`) once per turn. It chops a tree by accident, crafts when it
happens to be able to, digs down on a timer, and reliably stalls around the stone pickaxe. It is the
control that answers "did the LLM actually plan?"

---

## Sim module

The sim is **Nim**, in the starter's module layout, under `src/minecraft/`. The fork is a rename sweep
(`ctf` → `minecraft`, `CTF_WIRE` → `MINECRAFT_WIRE`; a CI grep asserts no `ctf_` / `CTF_` identifier
survives outside comment history) plus the changes below. **The same modules compile twice**: natively
into `/bin/minecraft` for the server, and to wasm through `replay-viewer/config.nims`
(`switch("path", rootDir / "src")`) for the viewer — which is the whole reason the game lives in the
starter's language and the whole reason Malmo, a JVM Minecraft server or MineRL's Python stack is not
an option here.

### Kept, by path (fork = retarget in place; byte-for-byte = do not edit)

| Starter path → fork | Treatment | Why |
|---|---|---|
| `src/ctf/server.nim` → `src/minecraft/server.nim` | **fork**, three named edits below | the mummy HTTP/websocket server, `/healthz`, `/player?slot&token`, `/global`, `/client/*`, `/replay-data`, join/auth/kick, the frame limiter, replay mode, the `COGAME_*` contract, `declarePlayerFailure`'s closed payload, the artifact-write block, the `wallClockBudgetSeconds` stop at `server.nim:1407-1417`, and the `Ping → Pong` branch in `websocketHandler` (kept verbatim — lux-ai 0.1.0 / snake-royale 0.1.0 both lost it; and **no** `kind != TextMessage` guard, which would drop the seat's binary registration frames) |
| `src/ctf/replays.nim`, `replay_runtime.nim` → `src/minecraft/` | **fork** (magic + game name only: `CtfReplayMagic = "COWLDCTF"` (`replays.nim:142`) → **`MinecraftReplayMagic = "COWLDMCR"`**) | the whole replay codec, keyframes, the incremental scan, lull spans, beat events, seek/speed/transport commands, `checkReplayHash`, `initReplayRuntime` / `advanceReplayFrame` / `buildReplayViewerPacket` |
| `src/ctf/decide.nim`, `directives.nim`, `llm.nim`, `baselines.nim`, `control.nim` → `src/minecraft/` (`control.nim` → `driver.nim`) | **fork**, retargeted not rewritten | the per-turn batch (`decide.nim:427`), the two deadlines, `turnSpacingMs` (`decide.nim:384-389`), the budget guard (`decide.nim:328-346`), tolerant parsing, the rune caps, the fallback ladder and its two log phrasings (`decide.nim:463`, `:491`) |
| `src/ctf/sim_state.nim` → `src/minecraft/sim_state.nim` | **fork** | `gameHash` / `mixHash`, `emitEvent`, logging, the lobby countdown, `resetToLobby` |
| `src/ctf/roster.nim` → `src/minecraft/roster.nim` | **fork**, three named edits below | join/auth/identities/`IdentityNames` (`roster.nim:64`), **`recordAchievement` (`:640-648`) and the `earnedAchievements` serialisation (`:828`) — kept and used as-is** under the name `recordMilestone`, and the results JSON builder (`squadResultsJson`, `:650`) |
| `src/ctf/events.nim` → `src/minecraft/events.nim` | **fork** | the tier-2 event wire format and the `eventsJsonl` summary-row contract; new `SimEventKind` values only |
| `src/ctf/broadcast.nim` → `src/minecraft/broadcast.nim` | **fork** | `stepEvents`, `buildStateJson`, `rosterJson`, the lull scan, the beat timeline — retargeted fields, same structure |
| `src/ctf/global.nim` → `src/minecraft/global.nim` | **fork**, three named edits below | the sprite/object pools, the compositor, the FX families |
| `src/ctf/labels.nim`, `rig_art.nim`, `wire_constants.nim`, `tools/gen_wire_constants.nim` | **fork** | the label vocabulary contract (+ `tests/label_manifest.txt`), the sprite compositor, the one-source JS wire constants |
| `src/ctf/sim_types.nim` → `src/minecraft/sim_types.nim` | **fork** | `GameVersion` (restarts at `"1"`, with the starter's prepend-only changelog-comment discipline and `tools/ci/check_gameversion.sh` kept), `TargetFps = 24` (`:376`), the flatty wire types (field order sacred), and the re-pinned `MaxSayRunes = 160`, `MaxNoteRunes = 400`, `MaxPromptRunes = 4000` |
| `src/ctf/sim_config.nim` → `src/minecraft/sim_config.nim` | **fork** | `GameConfig` lifecycle, `config.update`, and the validators at `:688-713` (whole-second `attempt1Ms`/`retryMs`, `attempt1Ms + retryMs ≤ turnBudgetMs`, positive `wallClockBudgetSeconds`) — all kept, and §Decisions' numbers are chosen to satisfy them |
| `src/ctf.nim` → `src/minecraft.nim` | **fork** | the entrypoint, **including seed randomisation before `config.update`** so the world generator follows the final seed |
| `src/paintball_player.nim` → `src/minecraft_player.nim` | **fork** | the thin seat registrar (§Decisions) |
| `client/chrome_common.js` | **byte-for-byte** (40 022 bytes, sha256 `7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c`) | §Viewer |
| `client/broadcast_core.js`, `replay_broadcast.html`, `league_replayer.html` | **fork** | §Viewer |
| `replay-viewer/config.nims`, `static_replay.js`, `static_replay_worker.js` | **fork: identifiers and the output name only** | the emscripten link flags and the Worker bootstrap (§Viewer) |
| `replay-viewer/ctf_replay.nim` → `replay-viewer/minecraft_replay.nim` | **fork** | §Viewer |
| `Dockerfile`, `Dockerfile.replay-viewer`, `tools/build_replay_viewer.sh`, `tools/wasm_replay_smoke.cjs`, `tools/expand_replay.nim`, `tools/extract_events.nim`, `tools/replay_summary.py`, `tools/tune_baselines.nim`, `nimby.lock`, `flake.nix`, `tests/config.nims` | **byte-for-byte apart from names/paths** | build, bundle and forensics wiring; `build_replay_viewer.sh` already carries the ecos `mkdir -p "$(dirname …)"` fix and the buildx / `--platform linux/amd64` handling, and its `docker cp` source path changes from `/workspace/ctf/replay-viewer/dist/.` to `/workspace/minecraft/replay-viewer/dist/.` |
| `tools/ci/check_gameversion.sh`, `tools/ci/next_coworld_version.py` (+ its test) | **byte-for-byte** | version discipline |
| `data/arena_floor.png`, `data/font.ttf`, `data/ascii.png`, `data/pallete.png`, `data/atlas/*`, `data/soldier_red.png`, `data/soldier_red_front.png`, `client/art/walls/{wall_h,wall_v}.jpg`, `client/art/lockerroom/{bg.jpg,red_*.webp}` | **byte-for-byte** | real art (§Viewer → Art) |

### Deleted (with their tests, tools, docs and config surfaces), not disabled

The hitscan gun and its jitter/exposure model, aim decoupling and vision cones, **fog-of-war
raycasting and the first-person raycast pipeline** (replaced by the plain rectangular window above and
a 2-D inset), spray cans, floor paint and the paint grid, the paint buff, King of the Hill and
`hillTicks`, the `resident`/`visitor` regimes, hearts/flags/capture/carriers, grenades and the
barrage, med kits, shields, cardboard barriers, trenches, perks, handicaps, lives and respawns,
**teams and four-team free-for-all** (there is one seat), **shouts-as-cog-speech and `ShoutMaxChars`**,
ctf's own fifteen paintball achievement **ids** (`src/ctf/sim.nim:2900-2932` — the *ledger* survives,
the *ids* do not), campaign mode, `maxGames > 1` side-swapping, and **all of the pixel-space map
machinery**: `arena.nim`'s wall masks and pixel queries, `map_art.nim`, `mapgen_styles.nim`,
`map_pool.nim`, `paint.nim`, `tools/mapkit.nim`, `tools/map_editor*.nim`, `tools/gen_map_pool.nim`,
`tools/render_map_pool.nim`, `docs/pool-review.html`, `docs/MAPKIT.md`. The world here is four stacked
32 × 32 integer cell grids built by a seeded noise generator in code; every one of those is a config
surface the mining rules would otherwise have to reason about.

Also deleted: the `data/` art belonging to deleted mechanics (`heart_*`, `ped_*`, `paintgun*`,
`medkit`, `shield`, `paintbomb`, `spraycan*`, `crew`, `*_crown`, `*_front_gun`,
`soldier_{blue,green,yellow}*`, `rig_real/`) and the blue/green/yellow locker-room webps — there is one
cog and it is red.

### New modules

- `src/minecraft/world.nim` — the block enum, the glyph/walkable/tier/drop tables, the **integer
  value-noise** generator and its three fields per level, the five-step playability post-pass, the
  four-level grid type and `shaftDown`, 4-adjacency in the fixed order north/east/south/west, the BFS
  used by `goto` and by `miner`, the depth-dependent window, and the 16 × 16 region downsample with its
  priority order. Pure integer; no pixie, no pixel queries.
- `src/minecraft/agent.nim` — the cog record (position, level, facing, inventory, tools, `tier`), the
  seventeen primitives of tick step 3 with their exact effects, `dig_down`'s six numbered cases, and
  the eight recipes with their adjacency requirements.
- `src/minecraft/milestones.nim` — the eleven ids in ladder order, their point values `2^i`, their
  predicates over sim state, the `milestoneTick[11]` array, `milestoneScore` and `speedBonus`, and the
  bridge to the starter's `recordAchievement` (as `recordMilestone`).
- `src/minecraft/sim.nim` — the step loop of §The game exactly as numbered, `gameHash`, end
  evaluation, scoring, and the seat's observation builder. Imports and re-exports the sim modules, as
  the starter's does, so `import minecraft/sim` sees everything.

There is deliberately **no `creatures.nim`**: this game has no mobs, and that absence is the main thing
that makes it a different game from `cogame-crafter` on the same stack.

### Integer arithmetic and determinism

**All sim arithmetic is integer only** — cell coordinates, the noise lattice and its fixed-point
interpolation, inventory counts, tick counters, BFS distances, milestone ticks, scores. There is no
floating point anywhere in `sim.nim`, `world.nim`, `agent.nim`, `milestones.nim`, `driver.nim` or
`baselines.nim`, and a test greps for it. That makes the native ↔ wasm hash chain exact by
construction.

**One seeded source, and it is a hash, not a stream.** Every generated quantity — the three noise
fields per level and every ore/lava draw — is a read of the pure hash `mix64(seed, salt, …)`
(splitmix64 over the mixed words), evaluated independently. Nothing the policy does can shift a draw,
reorder draws, or consume one out from under a later tick: **the world of seed `s` is the same world
no matter how the cog plays it**, which is the strongest form of the idea's "seeded worlds" and what
makes per-rung success rates comparable across policies. `tests/test_minecraft_world.nim` asserts it by
generating the same seed under three different policy behaviours and comparing all four 32 × 32 grids
byte for byte. **There is no runtime randomness at all** — no spawns, no mobs, no probabilistic
mining — so the sim is a pure function of `(seed, variant, plan sequence)`.

The seed is randomised in `src/minecraft.nim` before `config.update` (the starter's rule), recorded in
the replay config and in `results.seed`. Two episodes with the same seed and the same plans are
byte-identical.

### Determinism, native ↔ wasm

The mechanism is the starter's, unchanged, and it is why the starter is worth forking:

1. The server writes a **`COWLDMCR`** replay: magic + format version + game name/version header, the
   **resolved config JSON** (seed, variant, `num_agents`, every rule constant, `players[].name`,
   `slots[]`, `fastMode`), then the record stream — the join record, **per-turn plan records** (the
   only inputs this game has), chat records (`register` / `directive` / `fallback` / `budget_guard` /
   `stop` / `result`) and **one `gameHash` per tick**.
2. `tools/build_replay_viewer.sh` builds `replay-viewer/minecraft_replay.nim` — which imports the
   **same** `src/minecraft/sim.nim` — through the pinned `emscripten/emsdk:4.0.15` + nimby container in
   `Dockerfile.replay-viewer`, target `replay-viewer-builder`.
3. In the browser, `minecraft_load_replay` runs `parseReplayBytes` + `initReplayRuntime`;
   `minecraft_frame` re-steps the sim from the recorded plans and compares `sim.gameHash()` against the
   recorded hash **every tick** (`checkReplayHash`). One divergent bit is caught at the tick it happens
   and surfaced as `mismatchTick` in `#mmwarn`.
4. **`gameHash` mixes**, in this fixed order: `tick`; the cog's `(x, y, z, facing)`; the eight
   inventory counts; the three tool bits; the 11-bit milestone mask; then a rolling world digest
   updated **incrementally** on every block mutation (mine, place, shaft) rather than by scanning 4096
   cells a tick — the digest is `worldHash = mixHash(worldHash, z, x, y, oldBlock, newBlock)`, seeded
   at generation by folding all four grids and the `shaftDown` planes once.
5. **The wall-clock stop is recorded as a load-bearing record, not inferred.** A wall-clock fact cannot
   be re-derived from sim state, so the stop is written as one record applied by the *same proc* on
   record and on playback, and `tests/test_minecraft_replay.nim` runs the record → re-derive check for
   **every** end reason (`diamond`, `death`, `turnCap`, `tickCap`, `wallClock`, `fault`), not just the
   healthy one (particle-worlds `13c66d7`, 2026-08-26).

Replay size: ≤ 960 hashes + ≤ 48 plan records + ~60 chat records ≈ **22 KB**. Everything else — all
four 32 × 32 levels, every ore, every lava pocket — is re-generated in the browser from the seed and
the variant.

### Documented divergences (mirrored into `docs/PORTING-MINECRAFT.md`)

1. **No Malmo, no MineRL, no MineDojo, no Minecraft, and no bit-exactness with any of them.** Decided
   as a scoping rail before design. Minecraft is a JVM game behind Malmo's C++/Python bridge; MineRL is
   Python + a JVM server; MineDojo adds a task suite and a video-pretrained reward model. Embedding any
   of them means a simulator that cannot compile to wasm, so the static replay viewer — a non-optional
   pin — would be impossible, and a per-frame pixel policy interface is not a coworld interface. No
   upstream code is vendored, no upstream numbers are claimed as reproduced, and no score from this
   coworld is comparable to a published MineRL, VPT or Voyager figure. What *is* reproduced is the
   **problem**: the ObtainDiamond ladder, rung for rung, in a seeded world you have to dig through.
2. **Top-down 2-D cells on four discrete levels, not 3-D voxels with a first-person camera.** The
   idea's "per-frame keys + camera" interface is explicitly the one it calls "heavy"; it also names the
   realistic alternative — "LLM agents work through a skill library (Voyager-style), which is the
   realistic coworld interface". This game's seventeen primitives plus three macros **are** that skill
   library, made explicit and made deterministic. There is no camera to aim, no continuous look, and no
   pixel observation.
3. **Integer value noise, not Minecraft's world generator.** A hashed lattice with fixed-point
   bilinear interpolation, because a float noise field cannot be hashed identically native and in wasm.
   Recognisably the same *kind* of world (grass and trees on top, stone and coal below it, iron deeper,
   diamond and lava at the bottom) and not the same worlds.
4. **Eleven rungs, not twelve, and a strict doubling.** MineRL's ObtainDiamond reward schedule is
   `log 1, planks 2, stick 4, crafting_table 4, wooden_pickaxe 8, cobblestone 16, furnace 32,
   stone_pickaxe 32, iron_ore 64, iron_ingot 128, iron_pickaxe 256, diamond 1024`. This game drops
   `stick` as a *scored* rung (it is still a required crafted item), and re-values the remaining eleven
   as a **strict doubling** `1, 2, 4, …, 1024`. The reason is rankability: MineRL's schedule contains
   two ties (`stick`/`crafting_table` at 4, `furnace`/`stone_pickaxe` at 32) which make two materially
   different runs score identically, and a league needs a total order. The doubling makes
   `milestoneScore` exactly the milestone bitmask and makes "one rung deeper always wins" an integer
   identity rather than a convention.
5. **Episode length.** MineRL's ObtainDiamond allows 18 000 steps (15 minutes at 20 Hz); this game
   allows **960** (`deepcut`: 640), because the seat is an LLM on a 720 s budget (§Decisions). The world
   size, the ore densities and the recipe costs are all scaled to that budget so the ladder is
   genuinely completable — `tests/test_minecraft_sim.nim` asserts a reference solver reaches `diamond`
   on every committed fixture seed and that the `miner` baseline reaches at least rung 9 on the
   majority of `standard` seeds.
6. **Actions are batched under a driver, not stepped one per call.** Up to twenty primitives per LLM
   turn under a deterministic driver, plus three macros (`goto`, `move`, `tunnel`) and an `n`
   multiplier. One LLM call per primitive would be 960 calls in a 720 s budget — impossible — and a
   policy that cannot express "tunnel east" spends every turn walking. The **interrupt rule** (tick
   step 8) is what keeps batching from removing reactivity.
7. **No survival layer at all.** No hunger, no health bar, no mobs, no day/night, no drowning, no fall
   damage, no tool durability. Minecraft has all of them and `cogame-crafter` already ships a coworld
   about them. Here the only lethal thing is lava and the only clock is the deadline, because the thing
   being measured is **how deep a policy can plan**, not whether it can stay fed.
8. **No BASALT, no MineDojo language tasks, no LLM judge.** The idea offers a judged-task league as an
   alternative motive; the coordinator ruled it out of v1 and §Out of scope records it.
9. **Trees are finite; mining stone leaves walkable `tunnel`; a shaft is permanent.** Stated because
   they are the ones an implementer guesses wrong.
10. **`maxGames = 1`** — the starter's multi-game episode is not used; a single run has no side to
    swap.

### The three named edits to `server.nim`

1. **Turn boundary** — unchanged in shape, with a variable turn length (the tick loop breaks early on
   an interrupt, a death or the diamond) and one seat in the batch.
2. **Registration interception** — the seat's Sprite v1 chat message (`0x81`, surfaced by
   `applyPlayerViewerMessage` as `chatText`) whose text parses as a registration object is consumed as
   registration, **not** applied as a shout and **not** written to the replay chat stream; the server
   writes a redacted `register` record instead (policy label and kind, never the prompt). The starter's
   "hold an unappliable registration and re-read it when the slot lands" behaviour is kept verbatim,
   and the server **logs loudly and refuses to start the game** when the joined seat has no register
   record (the grf-football 2026-08-27 silent-default scar). Any other chat text from the seat is
   dropped — the cog speaks through `say`.
3. **Wall-clock stop** — the starter's `wallClockBudgetSeconds` check at the top of every loop
   iteration (`server.nim:1407-1417`), kept, forcing `phase = GameOver`, `reason = deadline`,
   `endRule = wallClock`, and written as the load-bearing stop record of §Determinism point 5.

### The three named edits to `roster.nim`

1. **Alias.** `seatAlias(slot)` returns `IdentityNames[slot]` title-cased → **`Alpha`** for the only
   seat. The `IdentityNames` array itself (`roster.nim:64-65`) is unchanged. Board labels and the label
   manifest inherit the two-name-space rule with no further change, and `showPlayerLabels` is false.
2. **Milestone ids.** `recordAchievement` (`:640-648`) is kept **verbatim** and re-exported as
   `recordMilestone`; only the id vocabulary changes, from ctf's fifteen paintball ids to the eleven of
   §The eleven milestones, plus the parallel `milestoneTick[11]` array this fork adds beside
   `earnedAchievements`.
3. **`squadResultsJson` → `runResultsJson`** (`:650`) — one entry per seat, one entry in every
   seat-indexed array, keys exactly as §Server lists them.

### The three named edits to `global.nim`

1. **The board is one 32 × 32 cell grid at a time, not a pixel arena.**
   `buildSpriteProtocolPlayerUpdates` emits cell-space coordinates plus the cog's `z`; the raycast fov
   cache and shadowcasting are deleted and replaced by the window's boolean mask plus the per-level
   known-map mask, which the viewer draws as the two-level fog wash. The board's **native size is
   32 × 24 = 768 × 768 px**, one 24 px tile per cell, and the viewer draws the level the cog is
   currently on (§Viewer → Readouts).
2. **Block, overlay and workshop pools.** New pools `BlockBase` (a tile layer per level, redrawn
   incrementally on mutation, never per-frame from scratch), `ShaftOverlay` (sized to 64) and
   `WorkshopBase` (tables and furnaces, sized to 16), filled in ascending `(z, y, x)` and emitted
   incrementally like the starter's other object families.
3. **Baked block bed.** `arena_floor.png` is tiled and recoloured per block at install with pixie,
   exactly the way the starter bakes endzone paint, so the per-frame cost is the cog, the shaft
   overlays, the two fog masks and the chrome — never 1024 tile draws.

---

## Server, player, protocol

### The contract

The starter's, unchanged in shape (`docs/PROTOCOL.md` is forked, not rewritten): `COGAME_CONFIG_URI`
in; `COGAME_RESULTS_URI`, `COGAME_SAVE_REPLAY_URI`, `COGAME_PLAYER_FAILURE_URI`, `COGAME_EVENTS_URI`
out; `COGAME_LOAD_REPLAY_URI` + `/client/replay` for local replay mode; `HOST` / `PORT`; the player
socket at `/player?slot=0&token=<t>`.

The certifier's browser probes are served for real and registered **before** any catch-all asset route:
`GET /client/player?slot=&token=` (token-checked, and it must **not** open the player socket),
`GET /client/global`, the `/global` websocket's first message, and `/healthz` — all kept answering for
the `gameOverTicks` grace after artifacts are written (the lantern 0.1.1 and 0.1.3 scars). The player
websocket handler **closes unless the token matches the seat** (the certifier probes with a bad token —
cogame-flatland 0.1.1) and keeps the `Ping → Pong` branch. Global broadcasts are fire-and-forget so a
slow viewer can never stall the episode.

### Results document (closed schema; `runResultsJson` and the manifest `results_schema` list exactly these keys)

```json
{
  "names":              ["daveey"],
  "aliases":            ["Alpha"],
  "scores":             [255648],
  "win":                [true],
  "winner":             0,
  "reason":             "complete",
  "endRule":            "turnCap",
  "variant":            "standard",
  "seed":               1734029581,
  "milestoneIds":       ["log","planks","crafting_table","wooden_pickaxe","cobblestone",
                         "stone_pickaxe","iron_ore","furnace","iron_ingot","iron_pickaxe",
                         "diamond"],
  "milestonePoints":    [1,2,4,8,16,32,64,128,256,512,1024],
  "milestoneUnlocked":  [true,true,true,true,true,true,true,true,false,false,false],
  "milestoneTick":      [14,17,19,20,21,96,288,312,-1,-1,-1],
  "milestonesReached":  8,
  "milestonesOf":       11,
  "milestoneScore":     255,
  "parMilestones":      6,
  "deepestMilestone":   "furnace",
  "deepestTick":        312,
  "speedBonus":         648,
  "deathCause":         "none",
  "deepestLevel":       2,
  "ticksPerLevel":      [21, 75, 864, 0],
  "cellsSeen":          412,
  "cellsTotal":         4096,
  "blocksMined":        184,
  "blocksPlaced":       2,
  "itemsCrafted":       9,
  "ironSmelted":        0,
  "shaftsDug":          2,
  "bridgesPlaced":      1,
  "coalMined":          4,
  "ironOreMined":       2,
  "diamondsMined":      0,
  "invLog":             0,
  "invPlanks":          1,
  "invStick":           2,
  "invCobblestone":     6,
  "invCoal":            4,
  "invRawIron":         2,
  "invIronIngot":       0,
  "invDiamond":         0,
  "toolsOwned":         ["wooden_pickaxe","stone_pickaxe"],
  "interrupts":         3,
  "primitivesExecuted": 951,
  "actionsDropped":     2,
  "macrosUnreachable":  1,
  "repliesRepaired":    0,
  "finalTick":          960,
  "turnsPlayed":        48,
  "policyKinds":        ["llm"],
  "llmTurns":           47,
  "fallbackTurns":      1,
  "deadSeats":          [false],
  "stopDetail":         ""
}
```

`deathCause` is a closed enum: **`lava` | `none`** (`none` when the episode did not end in death).
`toolsOwned` is a subset of the three tool names in canonical order, `minItems: 0`, `maxItems: 3`.
`ticksPerLevel` is always 4 entries summing to `finalTick`. Seven identities hold in every results
document and are asserted by `tests/test_minecraft_engine.nim`:

1. `milestoneScore == Σ 2^i over i where milestoneUnlocked[i]`, and `milestonePoints[i] == 2^i`;
2. `milestonesReached == count(milestoneUnlocked)` and `milestonesOf == 11`;
3. `milestoneTick[i] >= 1` **iff** `milestoneUnlocked[i]`, and `-1` otherwise;
4. `deepestMilestone` is `milestoneIds[max i with milestoneUnlocked[i]]` (or `"none"`),
   `deepestTick == milestoneTick[that i]` (or `0`), and
   `speedBonus == (milestonesReached == 0 ? 0 : maxTicks - deepestTick)`;
5. `scores[0] == 1000 * milestoneScore + speedBonus`, and `win[0] == (milestonesReached >= parMilestones)`,
   and `winner == (win[0] ? 0 : null)`;
6. `endRule == "death"` **iff** `deathCause == "lava"`; `endRule == "diamond"` **iff**
   `milestoneUnlocked[10]`;
7. `primitivesExecuted <= finalTick <= maxTicks`, `turnsPlayed <= maxTurns`, and
   `sum(ticksPerLevel) == finalTick`.

The example above satisfies all seven: eight unlocked rungs give
`1+2+4+8+16+32+64+128 = 255`; the deepest unlocked rung is `furnace` (index 7) at tick 312, so
`speedBonus = 960 − 312 = 648`; `scores[0] = 1000 × 255 + 648 = 255 648`; `8 >= parMilestones 6` so
`win[0]` is true and `winner` is `0`; and `ticksPerLevel` sums to `21 + 75 + 864 + 0 = 960 = finalTick`.
`docs/RULES.md` ships this exact document as its worked example and
`tests/test_minecraft_engine.nim` case 1 asserts every one of the seven identities against it.

Adding a key means updating `runResultsJson`, the manifest's `results_schema` and
`tools/ci/docker_smoke.sh`'s expected-key set in the same commit — Coworld schemas are closed and
undeclared keys are dropped.

### Replay bytes (self-sufficient)

The replay stays the starter's **binary `COWLDMCR`** format — the static wasm viewer parses exactly
this, and a JSON replay would mean rewriting `replays.nim`, `replay_runtime.nim`,
`static_replay_worker.js` and `wasm_replay_smoke.cjs`, i.e. the machinery this fork exists to reuse
(the knights-archers precedent). The consequences are handled explicitly:

- CI's `docker-smoke` job sets **`SMOKE_REQUIRE_REPLAY_JSON=0`**, which the shared
  `tools/ci/docker_smoke.sh` supports by design (`SMOKE_REQUIRE_REPLAY_JSON`, template line 31).
- The repo ships the starter's **`tools/replay_summary.py`** (Python 3 stdlib only, no Nim, no Docker),
  retargeted: given a `.replay` path it prints **one strict-UTF-8 JSON object** to stdout —
  `{"protocol":"minecraft/v1","gameVersion":"1","seed":…,"variant":"…","names":[…],"aliases":[…],
  "policyKinds":[…],"tickCount":…,"plans":[…],"says":[…],"fallbacks":N,"milestones":[…],
  "results":{…}}` — by brace-matching the config JSON from the first `{` (the technique the starter's
  `AGENTS.md` documents for prod forensics) and decoding the chat records.
- **The phase-60 substitute for `docs/SPEC.md` §Definition of done check 4:**
  ```bash
  curl -sSL "$replay_url" -o /tmp/ep.replay
  python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
  jq -e . /tmp/ep.json >/dev/null                       # strict UTF-8 JSON: ok
  jq -r '.protocol, .results.reason, .results.endRule, .results.milestonesReached' /tmp/ep.json
  jq -r '[.plans[]|select(.source=="llm")]|length, .fallbacks, (.says|length)' /tmp/ep.json
  ```
  Require `protocol == "minecraft/v1"`, `results.reason == "complete"` (or the declared-acceptable
  `deadline`), `results.milestonesReached >= 4`, and the champion seat's plans with `source == "llm"`,
  real verbs (including at least one `goto` or `tunnel` and at least one `craft_*` or `place_*`) and
  non-empty `say` lines — not all fallbacks.

Everything the viewer needs is in the bytes; no server is contacted except S3 for the file:

| Replay content | Carries |
|---|---|
| header | magic `COWLDMCR`, format version, `gameName` `minecraft`, `gameVersion` `1` |
| config JSON | `seed`, `variant`, `num_agents`, `levelCount`, `levelSize`, `surfaceViewRadius`, `deepViewRadius`, `regionSize`, `turnTicks`, `maxTurns`, `maxTicks`, `veinThreshold`, the three `caveThreshold*`, the two `lavaChance*`, the five ore chances, the five minima, `parMilestones`, `maxActionsPerTurn`, `macroPrimitiveCap`, `players[].name` (real name), `slots[]`, `fastMode` |
| join | the seat's `name` (real policy name), `slot`, `token` |
| plans | per turn: the accepted action list — this game's entire input log |
| chats | `register` / `directive` / `fallback` / `budget_guard` / `stop` / `result` records |
| hashes | one `gameHash` per tick — the integrity chain the viewer checks |

**The world generator is code, compiled into both the binary and the wasm module**, and the replay
carries the seed, the variant and every rule constant; the viewer therefore reconstructs all four
levels, every ore and every lava pocket from bytes it already has, with no fetch. A generator change is
a `GameVersion` bump, and the committed fixtures' version sweep makes an unversioned change fail the
build.

### Record and event vocabulary

**A. Replay chat records** (written by the server, re-applied at playback into non-hashed fields; they
drive the broadcast feed and `replay_summary.py`, and can never affect the sim):

| `k` | Fields |
|---|---|
| `register` | `slot`, `alias`, `policy` (≤ 64 runes), `kind` (`llm`\|`scripted`), `baseline` |
| `directive` | `turn`, `tick`, `slot`, `alias`, `source` (`llm`\|`scripted`\|`fallback`), `latency_ms`, `actions` (the accepted array), `executed` (the primitives that ran), `truncated`, `dropped`, `unreachable`, `blocked`, `interrupted`, `say` (≤ 160 runes), `view` (the observation minus `notes`) |
| `fallback` | `turn`, `attempt` (1\|2), `cause`, `detail` (≤ 200 runes) |
| `budget_guard` | `turn`, `remaining_s` |
| `stop` | `tick`, `endRule` — the load-bearing wall-clock/fault stop |
| `result` | the full results document, written once at episode end |

**B. Derived broadcast events** — `stepEvents` (`broadcast.nim`, retargeted) derives these from state
deltas during playback, so they cost no replay bytes and are identical live and in replay. **A closed
enum of fifteen kinds, plus `end`:**

`turn` `{n, tick, ticks_left}`; `plan` `{n, verbs, truncated, dropped, unreachable, interrupted}`;
`say` `{text}`; `fallback` `{cause}`; `milestone` `{id, index, points, n, of, tick}`;
`mine` `{what, z, x, y, count}`; `craft` `{what, n}`; `smelt` `{n, ingots}`;
`place` `{what, z, x, y}`; `descend` `{from, to, x, y, first}`; `ascend` `{from, to, x, y}`;
`lava` `{z, x, y, adjacent}`; `bridge` `{z, x, y}`; `blocked` `{act, why}`; `death` `{by, tick}`;
plus `end` `{reason, endRule, milestones, of, score, tick}`.

`tests/test_minecraft_events.nim` asserts the emitted set equals exactly this list. `plan` fires once
per turn (≤ 48 an episode); `milestone` at most 11 times; `descend` with `first: true` at most 3 times.
Nothing here fires unconditionally per tick — `mine` coalesces consecutive mines of the same block kind
at the same cell into one row with a `count` — so the feed never floods.

**Beats** — the scrubber markers, and the only kinds the appended game block emits: **`milestone`,
`newdepth`, `death`, `fallback`, `end`.** `newdepth` is a `descend` with `first: true` (the cog's first
arrival at a level, ≤ 3 per episode). These are exactly the idea's watchability ask — a **milestone
timeline** — plus the two the transport always needs. `turn`, `plan`, `say`, `mine`, `craft`, `smelt`,
`place`, `ascend`, `lava`, `bridge` and `blocked` drive the feed, not the scrubber.

**C. Tier-2 analysis stream** — `COGAME_EVENTS_URI` gets the starter's JSON-lines `eventsJsonl`, with
`SimEventKind` reduced to `TurnStart, Directive, Fallback, Primitive, Mine, Craft, Smelt, Place,
Descend, Ascend, Lava, Bridge, Blocked, Milestone, Death` and the mandatory trailing summary row
(`type`, `ticks`, `events`, `gameVersion`) kept. `Primitive` is the per-tick row that makes this stream
a full action trace for `cogamer-rl` — ≤ 960 rows an episode, which is what an LLM-vs-RL ladder needs
and what the replay deliberately does not carry.

---

## Viewer

**A static wasm bundle. Never a pod.** The manifest declares
`"replay_viewer": {"bundle": "static-replay-viewer"}` under `game`, and `tools/build_replay_viewer.sh`
is coworld-ctf's hook — kept, with the image tag and the `docker cp` source path changed
(`/workspace/ctf/replay-viewer/dist/.` → `/workspace/minecraft/replay-viewer/dist/.`) — building
`Dockerfile.replay-viewer`'s `replay-viewer-builder` target and copying the dist out. It already
carries the ecos 2026-08-23 `mkdir -p "$(dirname …)"` fix and the buildx / `--platform linux/amd64`
handling. It stays committed **executable** (`coworld build` hard-requires `os.X_OK`). No
`/client/replay` live-server viewer is ever declared to the platform; the game still serves
`/client/replay` locally for developers.

### One starter supplies all four viewer files

**`replay-viewer/config.nims`, the wasm entry `.nim` (`replay-viewer/minecraft_replay.nim`, forked from
`replay-viewer/ctf_replay.nim`), `replay-viewer/static_replay.js` + `static_replay_worker.js`, and
`index.html` (built from `client/replay_broadcast.html`) ALL come from ONE starter: `coworld-ctf`** —
which is this repo's own starter. **Never a mixture.** Splicing one starter's shell onto another's
emscripten link flags (`MODULARIZE` / `EXPORT_NAME` vs an `onRuntimeInitialized` bootstrap) deadlocks
the viewer silently (cogame-lantern, 2026-08-23). The set is internally consistent and is kept as one
piece: the Worker sets `Module.onRuntimeInitialized` (`replay-viewer/static_replay_worker.js:188`), the
module is emitted **non-modularized** as `minecraft_replay.js`, `config.nims` keeps
`--os:linux --cpu:wasm32 --cc:clang` through `emcc`,
`--mm:arc --exceptions:goto -d:useMalloc -d:release -d:noSignalHandler`, `-O2`,
`--preload-file data@data`, `-s ALLOW_MEMORY_GROWTH`, **`-s ABORTING_MALLOC=1`** (non-negotiable: with
`-d:useMalloc` Nim never checks malloc for nil and wasm32 has no memory protection, so a failed
allocation would write through nil into address 0 and corrupt the module's own globals — the starter's
own comment at `replay-viewer/config.nims:35`), `-s FILESYSTEM=1`, `-s ENVIRONMENT=web,worker,node`,
`-s EXPORTED_RUNTIME_METHODS=HEAPU8` and
`EXPORTED_FUNCTIONS=_main,_malloc,_free,_minecraft_load_replay,_minecraft_frame,_minecraft_input,
_minecraft_packet_ptr,_minecraft_packet_len,_minecraft_mismatch_tick,_minecraft_error_ptr,
_minecraft_error_len,_minecraft_stage_ptr,_minecraft_stage_len`; and `static_replay_worker.js` does
`importScripts('./wire_constants.js', './broadcast_core.js', './minecraft_replay.js')` in that order
(the starter's line 239, renamed only).

`minecraft_replay.nim` keeps `ctf_replay.nim`'s structure exactly — the `stampStage` fixed progress
buffer that survives an allocation abort, `bytesFromPointer`, the try/except publishing `lastError`,
and the `emscripten_exit_with_live_runtime()` epilogue that stops Nim's generated `main` from running
module destructors while JS keeps calling in. Two additions:

- **A load-time pre-scan.** `minecraft_load_replay` re-simulates the whole episode once headlessly
  (≤ 960 ticks over four 1024-cell grids — about a millisecond in wasm), records the per-tick
  cumulative `milestoneScore`, the tick each rung lit, the level the cog was on at every tick, the beat
  ticks and the lull spans, then resets and renders frame 0. That is what lets the milestone timeline,
  the strata gauge and the scrubber beats draw at **full width on the first frame** instead of growing
  in.
- `minecraft_mismatch_tick` returns `checkReplayHash`'s divergence tick, or `-1`.

**Load and error signals.** The shell sets **`data-replay-loaded="true"` on `<html>`** in
`static_replay.js`'s `onWorkerMessage` `'loaded'` branch (`replay-viewer/static_replay.js:158-161`) —
posted by the Worker only *after* `ingestPacket()` (`static_replay_worker.js:64`) has handed
BroadcastCore the first frame and it has drawn, so the attribute means "a frame is on the canvas", not
"a file was fetched". On failure it sets **`data-replay-error`** on `<html>` with the message, in
`showFailure()` (`static_replay.js:8-20`). Both are coworld-ctf's own signals, inherited unchanged —
this fork adds neither and removes neither. The `coworld-replay` postMessage bridge's `ready` is posted
**from a callback fired after** `data-replay-loaded="true"` is set, never on rAF timing at the call site
(chorus `3c11c953`, 2026-08-24), or the softmax.com embed samples an unpainted shell.

### Chrome provenance

- **`client/chrome_common.js` is copied byte-for-byte** (40 022 bytes; sha256
  `7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c`). Not edited, not reformatted;
  `tests/test_minecraft_viewer.nim` pins that sha256 as a literal. Everything this game adds lives in
  the appended game block. Its `markBeat` / `renderBeatMarkers` / `ingestBeats` / `renderClock` /
  `renderTransport` / `ingestLullSpans` / `renderMomentum` remain; `ingestBeats` ignores kinds it does
  not know.
- **`client/replay_broadcast.html` is the starter's page with a game block appended** — never a rewrite
  that reuses its ids (cogame-gridlock, 2026-08-23). The starter's CSS, markup, `relayout()`
  (`client/replay_broadcast.html:4276-4325`), transport, endcard, locker-room loader, `?embed=1` mode
  and `.tiny` density system are untouched, and the block is installed through the starter's own splice
  hook: `window.PaintballChrome` (context built at `:4330`, installed at `:4337`, declared at `:4651`)
  is renamed `window.MinecraftChrome` and its `install(PB_CTX)` / `frame(s, ctx, jumped)` (`:2075`) /
  `event(e, s, ctx)` (`:3480-3481`) entry points are kept with the same signatures. The appended block
  replaces only the *contents* of the scorebug plate, adds the milestone ladder panel, the strata
  gauge, the inventory strip and the two-level fog wash, retargets the agent-view inset, the feed rows,
  the beat rendering, the momentum series and the endcard columns. The block sits after the starter's
  banner comment at `:4344` and a test asserts the starter's byte prefix is intact up to that marker
  and that the file only grows.
- **`client/broadcast_core.js` is forked** — it is paintbot's draw layer and this game has no flags,
  paint, hills, grenades or hearts. Kept and pinned function-by-function against the starter's text by
  `tests/test_minecraft_viewer.nim`: the canvas/DPR sizing, `relayout()`, **the whole
  camera/zoom/minimap block (`clampView`, `computeFit`, `zoomAt`, `setZoom`, `panBy`, `panByMap`,
  `panTo`, `resetView`, `attachMinimap`, `broadcast_core.js:249-600`) — kept verbatim, because this
  game needs it**, the feed queue and `pushFeed` **including its signature** (the cogball 0.1.4 latch
  scar: a signature drift threw mid-replay and latched `static_replay.js` into `failed`), `banner`, the
  beat and lull machinery, the endcard builder, the speed chips, the `?embed=1` path, and the
  `window.CTF_WIRE` → `window.MINECRAFT_WIRE` rename emitted by `tools/gen_wire_constants.nim`.
  Deleted: every ctf-specific draw call and the raycast FPV pipeline (the `#fpv` **canvas** is reused,
  the raycaster is not). Added: `drawBlocks`, `drawShafts`, `drawCog`, `drawFog`, `drawAgentView`,
  `drawLadder`, `drawStrata`, `drawInventory`.
- **Elements removed** (exactly these, and the JS that feeds them):
  - **`#povBadge`** (`replay_broadcast.html:1525`) and the `togglePov` wiring — with one seat there is
    nothing to select.
  - Inside the kept `#fpv`: **`#fpv-hp`** (`:1537`), **`#fpv-gear`** (`:1538`), **`#fpv-map`** and
    **`#fpv-map-canvas`** (`:1542-1543`) — there is no health bar in this game at all, and an
    un-fogged tactical map is exactly what the kept `#minimap` already is.
  - The ctf scorebug internals `.hillchip`, `.hcap`, `.flagicon`, `.lives-num`, `.lives-label`,
    `.squad-pip` (`:300-330`), `.pb-tags`, `.squad` (`:2219-2244`), and the `.ec-heart` endcard glyphs
    (`:1221-1231`).
  - The ctf beat CSS rules `.beat-marker.kill`, `.steal`, `.return`, `.capture` (`:919-934`) and
    `.gamestart`, `.hillflip`, `.tagout`, `.gameover` (`:4431-4443`) are **all removed** — none of those
    kinds is ever emitted here (there is nothing to kill), and they are replaced by CSS for exactly the
    five kinds §Server lists.
  - The perk and handicap badges (`renderTeamMeters`'s perk/handicap paths and their CSS, `:245`).
  - **Kept:** `#viewport`, `#stage`, `#board`, `#lightpool`, `#grain`, `#lockerroom` (`#lk-bg`,
    `#lk-art`, `#lk-sprites`, `#lk-cap`), `#chrome`, `#scorebug` with `#plates-l` / `#plates-r` /
    `#clock` / `#clock-time` / `#clock-caption` / `#ffwd-mini`, **`#fpv` with `#fpv-canvas`,
    `#fpv-hud`, `#fpv-name`, `#fpv-cap` and `#fpv-grip`** (repurposed: it becomes the cog's egocentric
    window, caption `AGENT VIEW 5×5` / `AGENT VIEW 11×11` depending on depth, `#fpv-name` reading
    `ALPHA · y=32 · FACING EAST`, still draggable and resizable by the starter's own grip),
    `#bannerlane`, `#killfeed`, `#mmwarn`, **`#transport` in full** (`#btn-restart`, `#btn-back`,
    `#btn-play`, `#btn-fwd`, `#btn-end`, `#btn-loop`, `#btn-skip`, `#btn-spoilers`, `#ffwd-chip`,
    `#win-chip`, `#tick-clock`, `#speedchips`), `#scrub` with `#momentum` / `#scrub-fill` / `#lulls` /
    `#scrub-win` / `#scrub-head`, `#endcard` with `#ec-headline` / `#ec-wincond` / `#ec-how` /
    `#ec-teams` / `#ec-replay`, and `#status`. **`#plates-r` is kept but rendered empty** — it is one of
    the scorebug's three flex columns and removing it would un-centre `#clock`; with one seat the
    single plate lives in `#plates-l`.

**Zoom decision: `#viewpanel` is KEPT — zoom bar, minimap and all.** The pin says the zoom bar and
minimap exist only for boards larger than the frame, and here the board genuinely is: each level is
32 × 32 cells (768 × 768 native px) and the default view shows **15 cells**, so five sixths of the
level is off-frame at any moment and the cog is tunnelling through a maze it is drawing as it goes.
That is the opposite of the fixed-arena forks, and it is the right call for exactly the reason the
starter's own comment gives at `client/replay_broadcast.html:4350` ("classic boards can be colossal").
Concretely:

- `#viewpanel`, `#minimap`, `#minimap-canvas`, `#zoombar`, `#zoom-in`, `#zoom-out`, `#zoom-slider`,
  `#zoom-read` (`replay_broadcast.html:1510-1521`) and the page's
  `core.attachMinimap($('minimap-canvas'))` call (`:4200`) are **all kept, unmodified**.
- **Follow-cam.** Because `fitScale` and `zoom` are related by `zoom = levelSize / cellsAcross`
  independently of the container width (`fitScale = W/768`, and showing `k` cells needs
  `scale = W/(24k)`, so `zoom = 768/(24k) = 32/k`), the game block sets
  **`core.setZoom(32 / cameraCells)` with `cameraCells = 15` → `zoom = 2.133`** once per board, and
  calls `core.panTo(cogX·24 + 12, cogY·24 + 12)` on every frame while follow is armed. Follow is armed
  at load; a user `panBy` / `panByMap` / minimap drag disarms it; `resetView()` (the starter's own
  binding) re-arms it and restores `cameraCells = 15`. `broadcast_core.js:355-370` resets `zoom` to
  `minZoom` whenever the board's native size changes, which happens exactly once at the first frame, so
  the block re-applies `setZoom` whenever it observes `getTransform().zoom === 1` with follow armed.
- The minimap therefore always draws (it is suppressed only at `zoom <= minZoom`,
  `broadcast_core.js:561`), showing **the whole 32 × 32 level the cog is on, as the cog has explored
  it**, with the white view box marking the 15 × 15 window. When the cog changes level the minimap
  swaps to the new level with a 200 ms cross-fade, which is the single clearest signal in the viewer
  that the run just went a floor deeper. `#zoom-read` is re-labelled to show the cells across
  (`15 CELLS`, `32 CELLS` at the fitted end) instead of `FIT`.

### Endcard and chrome label re-mapping

A forked ctf endcard silently ships paintbot's vocabulary — nothing in the starter's tests, in
`viewer_smoke.mjs` or in the label manifest covers spectator chrome strings, because `labels.nim`
deliberately scopes itself to the *policy* contract. The re-labelings are therefore enumerated here and
enforced by a test:

| Starter string (`client/replay_broadcast.html:line`) | Becomes |
|---|---|
| `<div class="ec-thead"><span>Player</span><span>K</span><span>D</span><span>Clstr</span><span>Cap</span></div>` (`:3795`) | `<span>#</span><span>Milestone</span><span>Points</span><span>Tick</span><span>Level</span>` |
| `<div class="ec-thead"><span>Cog</span><span>Tags</span><span>Out</span><span>Paint</span></div>` (`:3788`) | `<span>Cog</span><span>Rungs</span><span>Deepest</span><span>Score</span>` |
| `<span class="fl-cap">Lives left</span>` (`:3793`) | `<span class="fl-cap">Ladder</span>` |
| `<span class="fl-cap">Hill time</span>` (`:3786`) | `<span class="fl-cap">Ticks used</span>` |
| `<span class="momentum-label">LIVES LEAD</span>` (`:1576`) | `<span class="momentum-label">MILESTONE TIMELINE</span>` |
| `<span class="lives-label">Lives</span>` (`:2241`) | `<span class="depth-label">Depth</span>` |
| `<span class="lives-label pb-lbl">Hill</span>` (`:2224`) | `<span class="depth-label pb-lbl">Pickaxe</span>` |
| `.lk-cap` "Filling hoppers with fresh paint…" (`:1480`) | "Generating the world…" |
| `#clock-caption` "In the locker room" (`:1499`) | "Waiting for the cog" |
| `#mmwarn` "Replay hash mismatch — showing recorded inputs" (`:1524`) | "Replay hash mismatch at tick N — showing recorded actions" |
| `#fpv-cap` "EYES" (`:1545`) | "AGENT VIEW 5×5" (and "AGENT VIEW 11×11" at the surface) |
| `#btn-spoilers` title "Spoilers: kills / flag story / winner on the timeline ahead of the playhead (o)" (`:1564`) | "Spoilers: milestones and the ending on the timeline ahead of the playhead (o)" |
| `#zoom-read` "FIT" (`:1520`) | the cells across: `15 CELLS` … `32 CELLS` |
| team words `RED` / `BLUE` in `.ec-tname` / plates (`:2222`, `:2239`, `:3783`, `:3790`, `:3836`) | the seat's **alias** (`ALPHA`) on the plate, and `THE RUN` as the endcard section head |

**`tests/test_minecraft_endcard_labels.nim`** greps the built `index.html` and `broadcast_core.js` for
a forbidden-vocabulary list — `Lives`, `LIVES`, `Clstr`, `Cap<`, `flag`, `heart`, `paint`, `hopper`,
`hill`, `POV`, `EYES`, `spray`, `grenade`, `med kit`, `team`, `kill` — outside comment blocks, and
asserts **zero** matches; and asserts each replacement string above is present exactly once. (`kill`
**is** on the forbidden list here, unlike in cogame-crafter: this game has no mobs and nothing in it
can be killed.) A rename that reintroduces paintbot vocabulary fails the build.

### Transport rules

`relayout()` sets **`--band`** (the measured transport strip), `--topband` and **`--hudscale`** on
`:root`, unchanged (`client/replay_broadcast.html:4276-4325`). **No overlay sits in the transport
band**: the board is laid out between the two bands and every addition here (the milestone ladder
panel, the strata gauge, the inventory strip, the agent-view inset, `#viewpanel`, the feed) is
positioned inside the board region, in the letterbox gutters beside it, or in the top band. The
**endcard stops at `var(--band)`** (`#endcard { bottom: var(--band, 0px) }`, `:1047`, the starter's
rule, kept) so the scrubber stays clickable underneath, and it is **dismissed by every seek** (the
starter's `else { $('endcard').classList.remove('on'); }` path, kept). **Scrubber beats are clickable,
labelled buttons**: the appended block's `mcBeat(tick, kind, label)` — named with the `mc-` prefix so
it can never shadow `chrome_common.js`'s `markBeat` alias (`client/replay_broadcast.html:1635`; the
tandem 2026-08-23 hoisting trap, and the same prefix discipline the starter's own `pbBeat` at `:4475`
uses) — appends `<button class="beat-marker <kind>" title="…" aria-label="…">` to `#scrub` and seeks on
click. CSS exists for **every kind emitted and no others**: `.beat-marker.milestone`,
`.beat-marker.newdepth`, `.beat-marker.death`, `.beat-marker.fallback`, `.beat-marker.end`. The game
block never calls `markBeat`, so an unlabelled div marker cannot appear.

**Playback rate: one tick per three animation frames at 30 fps = 10 ticks/second** (speed chips
`[0.5, 1, 2, 4, 8]`, default 1), with the cog's position interpolated across the three frames so a step
glides rather than snapping and a mined block fades out over the three. A 960-tick episode therefore
plays for **96 s**, and even a 400-tick episode plays for 40 s, which is what lets
`viewer_smoke.mjs --soak 10` observe real advancement instead of a legitimately-finished replay (the
ecos 2026-08-23 scar).

### Readouts

1. **The board** — the 15 × 15 follow-cam window over **the level the cog is currently on**, drawn from
   the baked block bed: grass, sand, water and forest at the surface; grey stone, cut tunnels, coal,
   iron and diamond seams and lava below; the placed crafting table and furnace; and the shaft
   overlays. A level change swaps the whole bed with a 200 ms wipe, which is the moment the run gets
   deeper.
2. **The strata gauge** (this game's signature readout) — a vertical four-band column in the left
   gutter, top to bottom `y=64 / y=48 / y=32 / y=12`, each band drawn in its level's palette. The cog's
   marker sits in its band; every shaft the cog has cut is drawn as a vertical line joining two bands
   at the right x-offset; every ore in `known_ore` is a coloured pip at its depth. A spectator sees at a
   glance how deep this run got and how directly it got there — which is what the idea's "it's
   Minecraft" watchability ask actually reduces to on a 2-D board.
3. **The milestone ladder panel** (the idea's headline ask) — 11 chips in the left gutter, one column,
   in ladder order, each an icon, its name and its point value. Locked chips are drawn at 25 % opacity
   with a hairline border; the tick a rung unlocks it **flashes** (the starter's banner flash reused),
   fills with the palette's gold, stamps its tick beside it, and stays lit. This is the single most
   important readout in this game and it is why the ladder gets a whole gutter.
4. **The milestone timeline** — the starter's `#momentum` SVG retargeted to a step chart of cumulative
   `milestoneScore` against tick, **log-scaled on the y axis** so a doubling ladder reads as even steps
   rather than one cliff at the end, with the four level bands shaded behind it and the playhead
   marked. Filled from the load-time pre-scan, so it draws at full width on the first frame. A
   staircase that goes flat for four hundred ticks in the `y=32` band is the whole story of a lost run
   in one glance.
5. **Inventory strip** — eight resource counts (log, planks, stick, cobblestone, coal, raw iron, iron
   ingot, diamond) and three pickaxe chips (wooden / stone / iron), the chips lit when owned, under the
   plate.
6. **Clock** — `#clock` shows the big numeral **`6 / 11`**; `#clock-time` shows `y=32 · TICK 401/960`;
   `#clock-caption` shows `score 63 864 · 559 ticks left` (the running score is the current mask, 63,
   times 1000, plus the speed bonus the deepest rung so far has banked, `960 − 96 = 864` — exactly the
   §Server formula, evaluated live).
7. **Scorebug plate** — one plate in `#plates-l`: the seat's **real policy name** (spectator side only),
   its in-game alias `ALPHA`, the cog avatar from `data/soldier_red_front.png`, the running score as
   the numeral, the ladder count and inventory above, and a `↯` glyph if the seat has taken a fallback.
8. **The cog's window, inset** — the repurposed `#fpv` panel in the right gutter, drawing exactly the
   `view` array the seat receives, world-oriented, the cog at the centre, `?` cells black, captioned
   `AGENT VIEW 5×5` (or `11×11`) with `ALPHA · y=32 · FACING EAST` beneath. Draggable and resizable by
   the starter's own `#fpv-grip`. It is what shows a spectator how little the cog can see underground —
   and it visibly shrinks from 11 × 11 to 5 × 5 the moment the run goes below ground.
9. **Minimap and zoom** — `#viewpanel`, kept (above): the whole explored current level at a glance with
   the view box, and a zoom bar from `15 CELLS` to `32 CELLS`.
10. **Match feed** (`#killfeed`) — plain language, never internal notation: `CHOPPED AN OAK (3 LOGS)`,
    `CRAFTED 4 PLANKS`, `★ RUNG 3/11 — PUT DOWN A CRAFTING TABLE (+4)`,
    `★ RUNG 4/11 — MADE A WOODEN PICKAXE (+8)`, `DUG DOWN TO y=48`, `MINED COBBLESTONE (12)`,
    `SMELTED AN IRON INGOT`, `BRIDGED OVER THE LAVA`, `BROKE THROUGH ONTO LAVA — STAYED PUT`,
    `TOO SOFT A PICKAXE FOR IRON ORE`, `★ RUNG 11/11 — CUT A DIAMOND (+1024)`, `ALPHA STEPPED INTO LAVA`,
    `Alpha: "iron in the wall and a table already down - furnace here, then straight east"`, and
    `MISSED THE CALL — miner plan (timeout)`. The `say` lines and the plan lines are where a spectator
    sees the LLM playing.
11. **Endcard** — `8 OF 11 RUNGS — STOPPED AT THE FURNACE, 960 TICKS GONE` (or
    `11 OF 11 — DIAMOND AT TICK 604` / `STEPPED INTO LAVA AT y=32, TICK 388`), the 11-row ladder under
    the re-mapped header (`# | Milestone | Points | Tick | Level`) with every row present and the
    unearned ones greyed, a summary line (`184 blocks mined, 2 shafts cut, 9 items crafted, 412 of 4096
    cells seen, deepest y=32, 3 turns cut short by lava, 1 fallback turn`), and `SCORE 255 648`. It
    stops at `var(--band)` and any seek dismisses it.
12. **Transport and integrity** — play/pause, step back, +5 s, jump to end, loop, skip-lulls (a lull =
    40 consecutive ticks with no `milestone`, `mine`, `craft`, `smelt`, `place`, `descend` or `lava`
    event and no change in the cog's cell, from the pre-scan), spoilers switch, tick readout, speed
    chips, the scrubber with its five beat kinds, and `#mmwarn` on a hash mismatch — all the starter's,
    verbatim.

### Art

**Real art, from the starter's shipped assets plus install-time bakes — no placeholders, no
solid-colour squares, no downloads.** Every block is a **24 × 24 baked tile** in the palette from
`data/pallete.png`, produced by one pixie bake at install exactly the way the starter bakes endzone
paint: **grass** from `data/arena_floor.png` tiled and tinted green with a procedural blade fleck;
**sand** the same bed tinted ochre with a grain speckle; **water** two frames of the bed tinted blue
with an offset ripple, cycled at 2 Hz; **stone** and **bedrock** cut from `client/art/walls/wall_h.jpg`
and `wall_v.jpg` with a baked bevel — which is exactly the blocky, mortared look this game wants —
bedrock darker and flatter; **tunnel** the stone tile darkened and smoothed with a floor grain; **oak
tree** a procedural canopy over the grass tile with a trunk; **coal**, **iron** and **diamond ore** the
stone tile with a baked seam in black, rust-orange and cyan, each seam a distinct blob pattern so they
are told apart at 8 px; **lava** two frames of orange with a black crust, cycled at 4 Hz; **crafting
table** and **furnace** composed from the wall crops with a baked wooden / iron top, the furnace
carrying a lit mouth for the three frames after a `smelt`; the **shaft-down overlay** a black hole with
a lit rim and the **shaft-up overlay** a lit hole in the ceiling with a shaft of light. The **cog** is
`data/soldier_red.png` composited by `rig_art.nim` into 4 facings × 2 sizes = **8 chips**, with a
mining pose (a two-frame swing played on any `mine`, `dig_down` or `place_*` tick);
`data/soldier_red_front.png` is its avatar on the scorebug plate and in the agent-view caption. The 11
milestone icons are baked once from the blocks and tools they refer to (an oak for `log`, a plank pair
for `planks`, a table for `crafting_table`, a pickaxe silhouette per tier, a cobble for `cobblestone`,
an ore seam for `iron_ore`, a furnace for `furnace`, an ingot for `iron_ingot`, a cut gem for
`diamond`). Every chrome numeral and every ladder caption is set in `data/font.ttf`. The loading screen
is the starter's locker room (`client/art/lockerroom/bg.jpg` plus the four red webps) with the caption
re-labelled.

**No text is ever drawn onto the board layer.** Every string in this viewer is DOM chrome or is drawn
inside a fixed-size gutter panel (the ladder, the strata gauge, the inset, the plate, the feed). That
is a deliberate rule for a **pannable** board: with a camera over a 768 × 768 surface, a string baked
into board space would legitimately sit off-frame and make `--strict-text-bounds` meaningless. Keeping
the board text-free is what lets the flag stay **on** (§Tests).

### Legible at 360 px

The embedded featured-match iframe is ~360 px wide, so the chrome is checked **at 360 px**, not at
desktop width — and the starter already engineers exactly this: `relayout()` sets
`--hudscale = clamp(0.5, boardW/760, 1.6)` and toggles `#stage.tiny` at `boardW <= 620`, both kept
verbatim (`client/replay_broadcast.html:4307-4312`). The board's aspect is **768/768 = 1.000**. In a
360 × 203 frame, `relayout()` reserves `--topband` and `--band`, leaving a play region roughly
360 × 120; since `360/120 = 3.0 > 1.000`, **height binds**: the board region renders **120 × 120**, and
at `cameraCells = 15` that is **8 px per cell** with the cog dead centre — a chunky pixel render, which
is exactly the look this game wants. That letterbox leaves **two ~120 px gutters**, and this game uses
both: the **strata gauge and the milestone ladder in the left gutter**, and the **`#viewpanel` minimap
above the agent-view inset in the right**, so nothing ever overlaps the board and nothing ever enters
the transport band. Six rules are added and asserted by `tests/test_minecraft_viewer.nim`:

1. `.plate-name { flex: 1 1 auto; min-width: 3.2em; overflow: hidden; text-overflow: ellipsis }` so a
   policy name never collapses to "…".
2. Under `.tiny`, the single plate keeps only `alias + name + rung count + score`; the avatar shrinks
   to 10 px, the inventory strip drops its resource numerals to icon-plus-count at 8 px, and the
   fallback glyph moves inline.
3. Under `.tiny`, the milestone ladder renders as **2 columns × 6 rows of 9 px icon chips** with no
   captions (captions move to `title` tooltips), a lit chip carrying a 1 px gold ring so the
   locked/unlocked distinction survives at 9 px; the full-width layout restores the captions and the
   single column above 620 px. The strata gauge collapses to a **10 px-wide, 108 px-tall** strip pinned
   to the far left edge of the gutter (10 + 4 + 106 = the gutter's 120 px width, with the ladder's two
   9 px columns and their gaps filling the remainder).
4. Under `.tiny`, `#zoombar` is hidden and `#minimap` is pinned to 56 px square at the top of the right
   gutter; the agent-view inset is pinned to 56 px square beneath it (56 + 8 + 56 = 120 px, exactly the
   gutter height) and the `#fpv-grip` resize is disabled below 620 px so the inset can never be dragged
   over the board.
5. Under `.tiny`, the fog wash uses a **higher-contrast two-step** (unseen black / seen dim) instead of
   the three-step, because an 8 px cell cannot carry three wash levels and still show an ore seam; and
   the ore seams are drawn at full saturation regardless of wash level, since finding ore is the thing
   the spectator is watching for.
6. `#killfeed` shows **three** rows under `.tiny` instead of six, and every feed row is single-line with
   `text-overflow: ellipsis`; the `say` rows keep their full text in `title`.

---

## Packaging

- **Repo**: `Metta-AI/cogame-minecraft`, **public at creation** (public is a certification
  prerequisite — `source-resolves` 404s on private). Slug `minecraft`; **`game.name` is `minecraft`** —
  identical to the slug, so the secret namespace `secret://coworld/minecraft/anthropic_api_key`, the
  page slug, the `POST /coworld-league-seeds` body and the docs all agree (the commons-family
  2026-08-24 scar, where `game.name` and the slug differed by an underscore).
- **`compose.yaml`** — **one** service, because the manifest image placeholder is derived from the
  compose service name (`{{GAME_IMAGE}}` is not a thing — lantern 0.1.0). ctf ships two services/two
  images (`compose.yaml` `game` + `player`); this fork uses the one-image / two-entrypoints shape
  because the shared `docker_smoke.sh` and `policies.json` assume a single image (the knights-archers
  precedent):

  ```yaml
  services:
    minecraft:
      image: coworld-minecraft:latest
      platform: linux/amd64
      build:
        context: .
        dockerfile: Dockerfile
        network: host
  ```

  ⇒ placeholder `{{MINECRAFT_IMAGE}}`.
- **`Dockerfile`** — the starter's two-stage debian-slim + nimby layout verbatim in structure (pinned
  nimby 0.1.26, `nimby use 2.2.4`, `nimby --global sync nimby.lock`), building **two** binaries:
  `nim c -d:release -d:useMalloc --opt:speed --stackTrace:on --out:minecraft src/minecraft.nim` →
  `/bin/minecraft`, and the same for `src/minecraft_player.nim` → `/bin/minecraft-player`. The runtime
  stage copies both binaries, `data/`, `client/`, `*.json`. `CMD ["/bin/minecraft"]`, runtime
  `--platform=linux/amd64`.
- **`Dockerfile.replay-viewer`** — the starter's verbatim (pinned `emscripten/emsdk:4.0.15`, pinned
  nimby with its sha256 check, the marker splices, the whole `test -f` / `grep -q` assertion block) with
  the asset list swapped to `data/{arena_floor,ascii,pallete}.png`, `data/soldier_red{,_front}.png`,
  `data/font.ttf`, `client/art/walls/*`, `client/art/lockerroom/{bg.jpg,red_*.webp}`,
  `minecraft_replay.{js,wasm,data}`, `wire_constants.js`, `broadcast_core.js`, `chrome_common.js`,
  `static_replay.js`, `static_replay_worker.js`, `index.html`.
- **`coworld_manifest_template.json`** — the starter's `coworld_manifest_paintbot.json` as the shape,
  with these decisions:
  - `$schema` present; top-level `tags: ["minecraft", "mining", "crafting", "tech-tree",
    "single-agent", "long-horizon"]` (≥ 3; `game.tags` must **not** exist — pistonball 0.1.0);
    **`episode_timeout_minutes: 20` at the top level**, not under `game`.
  - `game.name = "minecraft"`, `game.owner = "daveey@softmax.com"`, `game.description` present
    (required), `game.runnable.type = "game"`, `game.runnable.run = ["/bin/minecraft"]`,
    `game.replay_viewer = {"bundle": "static-replay-viewer"}` **under `game`** (not top-level),
    `game.runnable.env.ANTHROPIC_API_KEY_URI = "secret://coworld/minecraft/anthropic_api_key"`.
  - `game.config_schema` a real JSON Schema, `additionalProperties: false`,
    `required: ["tokens", "players"]`; **every array property carries `minItems`/`maxItems`**
    (`tokens` 1/1, `players` 1/1, `slots` 0/1 — the tandem 0.1.0 scar; there are no other arrays).
    `tokens` is described as runner-injected; **no `game_config` anywhere in this manifest contains a
    literal `tokens` array** (matriculate rejects "game_config must not include runner-managed tokens"
    — knights-archers 0.1.0), while `config_schema` keeps *requiring* it because the runner injects it.
    Properties: `tokens`, `players`, `slots`, `seed`, `num_agents`, `minPlayers`, `levelCount`,
    `levelSize`, `surfaceViewRadius`, `deepViewRadius`, `regionSize`, `turnTicks`, `maxTurns`,
    `maxTicks`, `veinThreshold`, `caveThresholdStone`, `caveThresholdIron`, `caveThresholdDiamond`,
    `lavaChanceIron`, `lavaChanceDiamond`, `coalChanceStone`, `coalChanceIron`, `ironChanceIron`,
    `ironChanceDiamond`, `diamondChance`, `minCoalStone`, `minIronIron`, `minCoalIron`, `minDiamond`,
    `minIronDiamond`, `parMilestones`, `maxActionsPerTurn`, `macroPrimitiveCap`, `attempt1Ms`,
    `retryMs`, `turnBudgetMs`, `turnSpacingMs`, `wallClockBudgetSeconds`, `lobbyJoinTimeoutTicks`,
    `gameOverTicks`, `fastMode`, `showPlayerLabels`, `model`, `maxOutputTokens` — with `num_agents` an
    integer, `minimum: 1`, `maximum: 1`, default 1.
  - `game.results_schema` closed and exactly the keys in §Server, with
    `reason: {"type":"string","enum":["complete","deadline","fault"]}`,
    `endRule: {"type":"string","enum":["diamond","death","turnCap","tickCap","wallClock","fault"]}`,
    `deathCause: {"type":"string","enum":["lava","none"]}`,
    `milestoneIds` / `milestonePoints` / `milestoneUnlocked` / `milestoneTick` each
    `minItems: 11, maxItems: 11`, `ticksPerLevel` `minItems: 4, maxItems: 4`, and `toolsOwned`
    `minItems: 0, maxItems: 3`.
  - **`game.protocols` carries BOTH `player` and `global`**, each
    `{"type":"uri","value":"https://github.com/Metta-AI/cogame-minecraft/blob/main/docs/PROTOCOL.md"}`
    — objects, never bare strings (the garble v0.1.0 scar).
  - **`game.docs`** = `{"readme": {"type":"uri","value":".../README.md"}, "pages": [
    {"id":"rules.md","title":"Rules","content":{"type":"uri","value":".../docs/RULES.md"}},
    {"id":"actions.md","title":"Actions and the reply format","content":{"type":"uri","value":".../docs/ACTIONS.md"}},
    {"id":"milestones.md","title":"The ObtainDiamond ladder","content":{"type":"uri","value":".../docs/MILESTONES.md"}},
    {"id":"porting.md","title":"What this is and is not a port of","content":{"type":"uri","value":".../docs/PORTING-MINECRAFT.md"}}]}`.
  - Top-level `player[]` with `id` / `type` / `name` / `description` / `image` / `run` / `source_url`
    and `resources: {requests: {cpu: "100m", memory: "64Mi"}, limits: {cpu: "1"}}` — **`limits.cpu` must
    be at least `"1"`** (pistonball 0.1.1). **Exactly ONE entry, `miner`**: `num_agents = 1` leaves
    exactly one certification slot, and **every declared player must occupy a certification slot** (the
    raid 0.1.2 scar), so a second declared player could not be seated. `scrounger` still ships in the
    image, is exercised by `tests/test_minecraft_driver.nim`, and is a league filler in
    `tools/ci/policies.json` — it is simply not a *declared manifest* player.

  **Variants — `num_agents: 1` inside each `game_config`, never at a variant's top level**
  (`CoworldVariant` is `additionalProperties: false` and the platform reads only
  `game_config.num_agents` — goofspiel-oshi-zumo 0.1.0):

  ```json
  "variants": [
    {"id": "standard", "name": "ObtainDiamond (1 cog, 960 ticks)",
     "description": "One cog, four stacked levels of a seeded blocky world, and the famous MineRL ladder: chop a log, craft planks, put down a crafting table, make a wooden pickaxe, mine cobblestone, make a stone pickaxe, find iron, build a furnace, smelt an ingot, make an iron pickaxe, and cut a diamond out of the rock at y=12. You cannot see through the floor, wood only exists on the surface, and lava kills. Every rung is worth double every rung below it put together, so the score is how deep the cog got - and how fast. The clock is 960 ticks and then the run is over wherever it stands.",
     "game_config": {"players": [{"name": "Alpha"}],
                     "num_agents": 1, "minPlayers": 1,
                     "levelCount": 4, "levelSize": 32,
                     "surfaceViewRadius": 5, "deepViewRadius": 2, "regionSize": 16,
                     "turnTicks": 20, "maxTurns": 48, "maxTicks": 960,
                     "veinThreshold": 600,
                     "caveThresholdStone": 880, "caveThresholdIron": 850,
                     "caveThresholdDiamond": 830,
                     "lavaChanceIron": 12, "lavaChanceDiamond": 30,
                     "coalChanceStone": 180, "coalChanceIron": 80,
                     "ironChanceIron": 140, "ironChanceDiamond": 110,
                     "diamondChance": 70,
                     "minCoalStone": 12, "minIronIron": 14, "minCoalIron": 6,
                     "minDiamond": 8, "minIronDiamond": 6,
                     "parMilestones": 6,
                     "maxActionsPerTurn": 12, "macroPrimitiveCap": 20,
                     "attempt1Ms": 6000, "retryMs": 3000,
                     "turnBudgetMs": 9500, "turnSpacingMs": 2600,
                     "wallClockBudgetSeconds": 660, "lobbyJoinTimeoutTicks": 2400,
                     "fastMode": true, "showPlayerLabels": false}},
    {"id": "deepcut", "name": "Deep cut (1 cog, two thirds of the clock)",
     "description": "The same four levels and the same eleven rungs, but only 640 ticks to climb them - and to make that possible the world is half again as rich in coal, iron and diamond, and half again as full of lava. There is no time to explore twice, no time to walk back up for forgotten planks, and no time to path around a lava lake you could have bridged. Score is how far up the ObtainDiamond ladder the cog gets before the clock stops, with speed as the tie-break.",
     "game_config": {"players": [{"name": "Alpha"}],
                     "num_agents": 1, "minPlayers": 1,
                     "levelCount": 4, "levelSize": 32,
                     "surfaceViewRadius": 5, "deepViewRadius": 2, "regionSize": 16,
                     "turnTicks": 20, "maxTurns": 32, "maxTicks": 640,
                     "veinThreshold": 600,
                     "caveThresholdStone": 880, "caveThresholdIron": 850,
                     "caveThresholdDiamond": 830,
                     "lavaChanceIron": 18, "lavaChanceDiamond": 45,
                     "coalChanceStone": 270, "coalChanceIron": 120,
                     "ironChanceIron": 210, "ironChanceDiamond": 165,
                     "diamondChance": 105,
                     "minCoalStone": 12, "minIronIron": 14, "minCoalIron": 6,
                     "minDiamond": 8, "minIronDiamond": 6,
                     "parMilestones": 5,
                     "maxActionsPerTurn": 12, "macroPrimitiveCap": 20,
                     "attempt1Ms": 6000, "retryMs": 3000,
                     "turnBudgetMs": 9500, "turnSpacingMs": 2600,
                     "wallClockBudgetSeconds": 660, "lobbyJoinTimeoutTicks": 2400,
                     "fastMode": true, "showPlayerLabels": false}}
  ]
  ```

  **Certification fixture** — `num_agents: 1` again, inside `certification.game_config`, and exactly one
  player so that
  `len(certification.players) == len(certification.game_config.players) == num_agents == SMOKE_SEATS == 1`
  (the four `SEAT-COUNT` invariants `tools/ci/docker_smoke.sh` cross-checks at template lines 141-150),
  with the single declared player seated:

  ```json
  "certification": {
    "players": [{"player_id": "miner"}],
    "game_config": {"players": [{"name": "Alpha"}],
                    "num_agents": 1, "minPlayers": 1, "seed": 42,
                    "levelCount": 4, "levelSize": 32,
                    "surfaceViewRadius": 5, "deepViewRadius": 2, "regionSize": 16,
                    "turnTicks": 20, "maxTurns": 48, "maxTicks": 960,
                    "veinThreshold": 600,
                    "caveThresholdStone": 880, "caveThresholdIron": 850,
                    "caveThresholdDiamond": 830,
                    "lavaChanceIron": 12, "lavaChanceDiamond": 30,
                    "coalChanceStone": 180, "coalChanceIron": 80,
                    "ironChanceIron": 140, "ironChanceDiamond": 110,
                    "diamondChance": 70,
                    "minCoalStone": 12, "minIronIron": 14, "minCoalIron": 6,
                    "minDiamond": 8, "minIronDiamond": 6,
                    "parMilestones": 6,
                    "maxActionsPerTurn": 12, "macroPrimitiveCap": 20,
                    "wallClockBudgetSeconds": 240, "lobbyJoinTimeoutTicks": 600,
                    "fastMode": true, "showPlayerLabels": false}
  }
  ```

  A `miner`-only episode is scripted throughout, so 960 ticks is about a second of sim, but the replay
  is long ⇒ **up to 96 s of playback**, which the viewer soak needs. Seed 42 is asserted by
  `tests/test_minecraft_engine.nim` to produce a fixture episode in which `miner` reaches **at least
  seven** rungs (so at least one `craft_*`, one `place_*`, one `mine` of an ore and one `dig_down`
  occur), descends to **at least `z = 2`**, runs for **at least 400 ticks** (so the replay outlasts a
  10 s soak by a wide margin), and hits at least one `blocked` and at least one `lava` event — so the
  smoke replay always exercises the `milestone`, `newdepth`, `blocked` and `lava` paths. The certify
  step in `coworld-release.yml` passes **`--timeout-seconds 300`** (the default 60 covers start +
  connect grace + play + linger — cooperative-hunting 0.1.3).
- **`tools/ci/policies.json`** — four policies, one image, `run: "/bin/minecraft-player"`, following the
  starter's `tools/ci/paintball_policies.json` shape (including `PLAYER_POLICY_LABEL`):

  ```json
  [{"name":"minecraft-obtaindiamond","run":"/bin/minecraft-player",
    "env":{"PLAYER_PROMPT":"<champion #1 text above>","PLAYER_POLICY_LABEL":"obtaindiamond"}},
   {"name":"minecraft-branchminer","run":"/bin/minecraft-player",
    "env":{"PLAYER_PROMPT":"<champion #2 text above>","PLAYER_POLICY_LABEL":"branchminer"},
    "player":"ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"},
   {"name":"minecraft-miner","run":"/bin/minecraft-player",
    "env":{"PLAYER_SCRIPTED":"miner","PLAYER_POLICY_LABEL":"miner"}},
   {"name":"minecraft-scrounger","run":"/bin/minecraft-player",
    "env":{"PLAYER_SCRIPTED":"scrounger","PLAYER_POLICY_LABEL":"scrounger"}}]
  ```

  Champions #1 and #2 are the two `PLAYER_PROMPT` policies (#1 owned by daveey, #2 by daveey-1, uploaded
  while daveey-1 is the active player); the fillers are `miner` and `scrounger`, and their versions
  must differ from the champions'. No `USE_BEDROCK` flag: the LLM call is made by the **game** pod.
- **CI** — `.github/workflows/ci.yml` is coworld-builder's `templates/ci.yml`: the `test` job keeps the
  template's nimby/Nim toolchain and runs every `tests/*.nim` in debug and release, and the
  `docker-smoke` and `wasm-viewer` jobs are taken **unchanged** with `<slug>` → `minecraft`, `<IMAGE>` →
  `coworld-minecraft`, `<SEATS>` → **`1`**, plus `SMOKE_REQUIRE_REPLAY_JSON=0` (§Server) and `--soak 10`
  added to the `viewer_smoke.mjs` invocation (which already passes `--strict-text-bounds`).
  `coworld-release.yml` and `coworld-submit.yml` are the templates, with `--timeout-seconds 300` on the
  certify step, and the push-triggered upload job gated on the `UPLOAD_REQUIRED` repo variable
  (derks-gym 0.1.1). `tools/ci/docker_smoke.sh` and `tools/build_replay_viewer.sh` are committed
  **executable** (mode 100755) — CI asserts the bit and invokes them by path.

---

## Tests

Nim, in the starter's layout: `tests/test_minecraft_*.nim`, imported by the four balanced shards
(`tests/shard_1..4.nim`) and by `tests/tests.nim`, run from the repo **root** with
`nim c -r tests/tests.nim` locally and by `ci.yml`'s `test` job (which runs every `tests/*.nim` in both
debug and `-d:release`). `tests/config.nims` (`--path:"../src"`) is the starter's, unchanged.

**Sim unit tests** (`tests/test_minecraft_world.nim`, `tests/test_minecraft_sim.nim`)

1. `world is a pure function of the seed` — the same `(seed, variant)` generates byte-identical grids
   for all four levels under three different policy behaviours, and two different seeds differ.
2. `generation invariants` — over 200 seeds and both variants: the bedrock ring is intact and unbroken
   on every level; the 3 × 3 block at `(16, 16, 0)` is grass and `(16, 16, 1)` is stone; a tree lies
   within Chebyshev 8 of spawn and `count(oak tree on z=0) >= 6`; the five global minima hold; each of
   `z ∈ {2, 3}` has ≥ 700 non-bedrock non-lava interior cells; every cell holds exactly one block from
   the closed enum.
3. `the world is completable` — over 60 seeds of each variant, a search-based reference solver
   (test-only, not shipped in the image) that ignores the turn budget reaches `diamond`; a seed where it
   cannot is a generator bug and fails the build. Additionally, the reference solver's tick count is
   ≤ 500 on `standard` and ≤ 420 on `deepcut`, which is what makes those deadlines honest.
4. `noise is integer` — a source grep over
   `src/minecraft/{sim,world,agent,milestones,driver,baselines}.nim` finds no `float`, `/`, `sqrt` or
   float literal; and the three noise fields per level are recomputed in a second, independent
   implementation in the test and compared cell for cell.
5. `glyph, walkable, tier and drop tables are total` over the block enum and match §The game exactly;
   the 17 glyphs are pairwise distinct.
6. `the seventeen primitives` — each does exactly what §The seventeen actions says and nothing else:
   `move_<dir>` turns then steps only into a walkable cell; `mine` respects the tier table and yields
   exactly the drop; every recipe checks its costs and its table/furnace adjacency **on the same
   level**; every `place_*` checks its cost and its target block; `place_block` only fills lava and
   water; crafting an owned pickaxe is a free no-op; an inapplicable primitive is a no-op that still
   costs a tick and emits the right `blocked{why}`.
7. `dig_down's six cases` — bedrock floor at `z=3`; an existing shaft is free and drops no item; lava
   below breaks the floor, does **not** move the cog, marks the cell permanently known and fires the
   interrupt; bedrock below and an insufficient tier both block; a legal dig collects the drop, writes
   `tunnel`, sets `shaftDown` and moves the cog. And `climb_up` works **only** where `shaftDown` is set
   on the level above at the same `(x, y)`.
8. `lava kills` — a `move_<dir>` into lava ends the episode on that tick with `endRule == "death"` and
   `deathCause == "lava"`; `place_block` over lava makes it `stone` and no longer fatal; a `dig_down`
   onto lava never kills.
9. `visibility` — the window is `11 × 11` at `z = 0` and `5 × 5` at `z ≥ 1`, world-oriented, cog at the
   centre, and no cell outside the box ever leaks into `view`; a level never descended to is entirely
   `?` in the known map; a shaft under the cog reveals exactly one cell below and nothing else; the
   known map grows only from observed windows.
10. `the 16 × 16 region map` — always 16 strings of 16, always of the **current level only**; each
    region's glyph is the highest-priority block that region is *known* to contain, by the exact
    priority order; a region with no observed cell is `?`.
11. `goto BFS` — the path is unique for a given known map (neighbour order north/east/south/west),
    never traverses `?`, water, lava, rock, ore, a table or a furnace, and **never changes `z`**; it
    ends **on** a traversable target and **facing** a non-traversable one; an unreachable target yields
    zero primitives; the path never exceeds `macroPrimitiveCap`.
12. `tunnel expands correctly` — `{"act":"tunnel","dir":d,"n":k}` expands to exactly `k` × (`mine`,
    `move_<d>`) in that order, is capped at `macroPrimitiveCap`, and its `mine` steps respect the tier
    table like any other `mine`.
13. `the eleven milestones` — for each rung, a scripted sequence that unlocks it and a deliberate near
    miss that does not (crafting a pickaxe with no table within 1; crafting with a table on the level
    above; smelting with no furnace; mining iron with a wooden pickaxe; mining diamond with a stone
    pickaxe; placing a table without 4 planks). Each unlocks at most once, is never revoked, and stamps
    `milestoneTick` exactly once, on the tick its predicate first holds.
14. `turn and tick order` — the numbered resolution order of §The game is exercised end to end: the
    queue empties into `noop` and the ticks are still consumed; a newly adjacent lava breaks the tick
    loop and a `blocked{no_tier}` does **not**; the diamond ends the episode on its tick; a death ends
    it on its tick; skipped ticks are never counted in `finalTick`.
15. `scoring` — over 500 randomised end states: `milestoneScore` equals the milestone mask read as an
    integer; `scores[0] == 1000 × milestoneScore + speedBonus`; the dominance bound holds
    (`maxTicks 960 < 1000` and `640 < 1000`); one rung deeper always outranks any subset of the rungs
    below it; the maximum is `2 047 959`, the minimum is `0`; `win[0]` is
    `milestonesReached >= parMilestones`; `winner` is `0` when `win[0]` and `null` otherwise.
16. `end conditions` — `diamond`, `death`, `turnCap`, `tickCap`, a forced wall-clock stop and a forced
    fault each produce the right `endRule` and the right episode `reason`; a wall-clock stop mid-run
    still scores every rung already unlocked; running out of ticks is `complete`, never `deadline`.
17. `tick budget` — 960 ticks of a full `standard` episode with every level visited complete in < 1 s
    in a release build.

**Bounded orders / legality on the scripted baselines** (`tests/test_minecraft_driver.nim`)

18. `baselines are bounded` — for 300 pseudo-random world states (both variants, all four levels, every
    inventory and tool combination, adjacent to lava, water, ore and a table) and for **both** `miner`
    and `scrounger`: the reply has at most 12 actions, every `act` is in the enum, `goto` targets are
    inside 0…31, `move`/`tunnel` dirs are in the enum, every `n` is inside its per-verb range, `say` and
    `notes` are empty, and the serialised directive is ≤ 1024 bytes. A baseline that ever proposes an
    illegal or unbounded action fails the build.
19. `baselines never suicide` — over the same states, neither baseline ever emits a plan whose
    deterministic expansion steps onto a **known** lava cell; `miner`'s BFS never routes through `?`.
20. `driver never produces an illegal primitive` — over the same states, every expanded queue is ≤ 20
    primitives, every entry is one of the seventeen, macros expand to at most `macroPrimitiveCap`, and
    an empty queue yields `noop`, never nothing.
21. `fallback is the miner proc` — the decision engine's fallback path and the `miner` baseline resolve
    to the same proc, so they cannot drift.
22. `reply validation` — the validator accepts the schema, **drops** (never rewrites) an invalid action,
    clamps `goto` coordinates and every `n`, lower-cases and `-`→`_` normalises `act`, case-folds and
    aliases `dir` (`up`→north etc.), accepts a `say`-only reply, rejects a non-object, truncates
    `say`/`notes` on **rune** boundaries at 160/400 with 4-byte emoji sitting exactly on the boundary,
    caps the read at 4096 bytes, caps `actions` at 12, and reports `truncated` / `dropped` /
    `unreachable` / `blocked` / `interrupted` back accurately.
23. `baseline tuning is the swept pick` — the shipped `miner` thresholds equal
    `tools/ci/baseline_tuning.json` (the starter's `test_tuning` pattern; `ci.yml` re-runs the sweep
    with `--check`).
24. `miner beats scrounger` — over 100 seeds of each variant, `miner`'s total `milestoneScore` is
    strictly greater than `scrounger`'s, `miner` reaches rung 9 or better on the majority of `standard`
    seeds, and `scrounger` reaches at least rung 1 — the two controls are genuinely different
    controllers and neither is a zero.

**End-to-end episode writing a replay** (`tests/test_minecraft_engine.nim`)

25. `episode writes artifacts` — run a real one-seat episode (`standard`, scripted, no API key so the
    LLM client is `disabled`) against a temp-dir `COGAME_*` URI set; assert `results.json` and the
    `.replay` are written, `reason == "complete"`, `scores` agree with the formula, the seven results
    identities of §Server hold, and the results key set equals the manifest's `results_schema` key set
    **exactly**.
26. `the cert seed is interesting` — seed 42 on `standard` yields ≥ 7 rungs including at least one
    `craft_*`, one `place_*`, one ore `mine` and one `dig_down`, reaches `z >= 2`, runs ≥ 400 ticks, and
    emits at least one `blocked` and one `lava` event — so the CI smoke replay always exercises those
    paths and always outlasts the soak.
27. `no seat can stall` — a seat that connects then never answers, and a seat that never connects at
    all, both produce a finished episode inside the wall-clock budget, with `fallbackTurns` counted,
    `deadSeats` set, and exactly one closed-schema `{"message","failed_policy_index"}` failure payload;
    the server refuses to start the game (loudly) when the joined seat has no register record.
28. `budget guard and rate guard settle early` — with each guard forced, the episode finishes
    `complete`, not `deadline`, and the matching record names the turn.
29. `interrupt accounting` — a forced newly-adjacent lava reveal mid-turn discards the rest of the
    queue, increments `interrupts`, sets `last_plan.interrupted = "lava_found"`, and does **not**
    consume the discarded ticks; a `blocked{no_tier}` does none of those things.

**Replay** (`tests/test_minecraft_replay.nim`)

30. `record then re-derive, every end reason` — for `diamond`, `death`, `turnCap`, `tickCap`,
    `wallClock` **and** `fault`, record an episode and re-derive it from the bytes; assert identical
    hashes at every tick **including the stop tick** (the particle-worlds scar).
31. `replay is self-sufficient` — the bytes alone yield the seat's real name, its alias, the policy
    kind, the full config (every constant in §Server's config-JSON row), the seed, the variant, every
    plan record, every chat record and the result; and re-simulating from them reproduces all four
    levels, every shaft and every milestone tick with no fetch.
32. `the incremental world digest equals a full fold` — after 960 ticks of mining, placing and digging,
    the incrementally maintained `worldHash` equals a fresh fold over all 4096 cells and all
    `shaftDown` planes. (The optimisation of §Determinism point 4 is only safe if this holds.)
33. **`replay_summary is strict UTF-8 JSON`** — run `tools/replay_summary.py` over a replay whose every
    capped field is filled to exactly its cap with 4-byte emoji; assert the output parses under a
    **strict** UTF-8 JSON parser, contains no lone surrogates, and reports `protocol == "minecraft/v1"`.
34. `determinism from the replay alone` — re-simulate from the replay's seed and plan records on a
    fresh sim; identical final tick, milestone mask, milestone ticks and per-tick `gameHash`.
35. `every committed fixture carries the current GameVersion` — the starter's sweep over `tests/`, kept.

**Manifest** (`tests/test_minecraft_manifest.nim`)

36. `manifest pins` — `num_agents == 1` in **both** variants' `game_config` **and** in
    `certification.game_config`; `num_agents` absent at every variant top level; no literal `tokens` in
    any `game_config`; `len(player) == 1` and that player seated in `certification.players`;
    `len(certification.players) == len(certification.game_config.players) == 1`; every array in
    `config_schema` has `minItems`/`maxItems`; `episode_timeout_minutes` top-level; both
    `game.protocols.player` and `.global` present as `{"type","value"}` objects; `game.docs.readme` +
    `pages`; `game.description` present and `game.tags` absent; ≥ 3 top-level tags;
    `player[].resources.limits.cpu >= "1"`; every `wallClockBudgetSeconds <= 660`;
    `attempt1Ms + retryMs <= turnBudgetMs` and both are whole seconds;
    `maxTicks == maxTurns × turnTicks`; `maxTicks < 1000` (the scoring dominance bound);
    `game.name` equals the slug and the secret URI's namespace; the `results_schema` milestone arrays
    are pinned at 11 and `ticksPerLevel` at 4; **and every variant's `game_config` actually constructs
    a valid `GameConfig`, generates its four levels, passes the generation invariants and produces the
    turn schedule this note claims** (the collab-cooking 0.1.1 scar: test every variant, not just the
    fixture).
37. `manifest loads under the installed CLI` — a CI step runs the installed `coworld`'s own
    `validate_upload_manifest` / `_load_template_manifest` (0.1.42 wants `game.replay_viewer`, no
    top-level `version`, no `game.display_name`, `game.owner` required, no runner-managed `tokens` —
    the collab-cooking 2026-08-25 scar).

**Viewer** (`tests/test_minecraft_viewer.nim`, static assertions in the `test` job)

38. `chrome_common is byte-identical` — sha256 of `client/chrome_common.js` equals
    `7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c`, pinned as a literal.
39. `broadcast html is starter plus block` — the file begins with the starter's bytes up to the
    documented splice marker (`replay_broadcast.html:4344`) and only appends after it;
    `broadcast_core.js`'s kept procs are byte-identical to the starter's, `pushFeed`'s signature and the
    whole camera/zoom/minimap block included.
40. `no shadowed chrome aliases` — no identifier in the appended game block collides with any name in
    `chrome_common.js`'s alias list (`replay_broadcast.html:1635`, the tandem hoisting trap); the beat
    builder is `mcBeat`, never `markBeat`.
41. `beat CSS matches emitted kinds` — the set of `.beat-marker.<kind>` rules equals exactly
    `{milestone, newdepth, death, fallback, end}`, and none of ctf's eight kinds survives.
42. `viewpanel is kept and wired` — `#viewpanel`, `#minimap`, `#minimap-canvas`, `#zoombar`, `#zoom-in`,
    `#zoom-out`, `#zoom-slider`, `#zoom-read` and the `core.attachMinimap($('minimap-canvas'))` call are
    all present; the game block calls `core.setZoom(32 / cameraCells)` with `cameraCells == 15` and
    calls `core.panTo` on every frame while follow is armed; the removed ids (`#povBadge`, `#fpv-hp`,
    `#fpv-gear`, `#fpv-map*`) appear nowhere, while the kept `#fpv`, `#fpv-canvas`, `#fpv-name`,
    `#fpv-cap` and `#fpv-grip` are all present.
43. `transport, endcard and 360 px rules` — `#endcard { bottom: var(--band` present; `relayout()` sets
    `--band`/`--topband`/`--hudscale` on `:root`; no game-block element is positioned inside the band;
    the six `.tiny` rules exist and both gutter arithmetics (right: 56 + 8 + 56 = 120; left:
    10 + 4 + 106 = 120) are asserted against the CSS.
44. `no canvas text on the board layer` — a grep over the appended block and `broadcast_core.js` finds
    no `fillText` / `strokeText` inside the board draw path (§Viewer → Art); every string is DOM or is
    drawn inside the gutter panels.
45. `endcard labels` — `tests/test_minecraft_endcard_labels.nim`: zero matches for the forbidden
    paintbot vocabulary outside comments, and each re-mapped string present exactly once (§Viewer).
46. `label manifest` — the starter's `test_label_contract` pattern: the emitted board-label vocabulary
    equals `tests/label_manifest.txt`, regenerated in the same commit as any label change.
47. `events are the closed enum` — `tests/test_minecraft_events.nim`: the set of kinds `stepEvents` can
    emit equals exactly the sixteen listed in §Server, and every kind used by the appended game block is
    in that set.

**Viewer smoke — the bundle is EXECUTED, not merely built**

48. **`tools/ci/viewer_smoke.mjs`** (copied verbatim from
    `coworld-builder/templates/tools/ci/viewer_smoke.mjs`) is run by **`ci.yml`'s `wasm-viewer` job**,
    which `needs: docker-smoke` and runs it against **the replay `docker-smoke` produced** (downloaded
    as the `smoke-replay` artifact), in headless chromium (Playwright pinned 1.55.0 in both the npm
    module and the browser download):
    `node tools/ci/viewer_smoke.mjs --bundle dist/static-replay-viewer --replay "$replay" --timeout 90
    --soak 10 --strict-text-bounds`. It fails the job unless `data-replay-loaded="true"` (or the bridge
    `ready` posted after it) arrives, the clock/tick readouts **advance** across the soak, and
    `canvas_text.never_inside == 0`. **`--strict-text-bounds` stays on even though the board is
    pannable**, because §Viewer → Art forbids any canvas text on the board layer: every string this
    viewer draws lives in a fixed-size gutter panel or in the DOM, so a text run outside its canvas is
    always a bug here.
49. **`tools/ci/renderer_fixture.html`**, run by its own `ci.yml` step with
    `viewer_smoke.mjs --strict-text-bounds` — because `docker_smoke.sh` runs with **no**
    `ANTHROPIC_API_KEY`, the CI replay's seat plays scripted and emits **no `say` at all**, so the smoke
    replay can never exercise the feed's narration path (the cogchemists 2026-08-24 scar). The fixture
    **loads the shipped `dist/static-replay-viewer/index.html` in an iframe** and shims only the wasm
    entry — it does not re-implement the drawing (the particle-worlds 2026-08-26 scar) — driving the
    real page with a full-cap 160-rune `say`, all 11 ladder chips in both states, the strata gauge at
    all four depths, a lava-death endcard, an `11 OF 11` diamond endcard and a `turnCap` endcard, at
    several canvas widths including 360 px.
50. **`tools/wasm_replay_smoke.cjs`** — the starter's headless-node run of the *exact emitted* wasm
    module against the committed fixtures, kept: wasm32-only failures (integer traps, address-space
    exhaustion) are invisible to the native shards, and this game's 960-tick, four-level replays are the
    biggest thing the module has to hold.

---

## Out of scope (v1)

- **BASALT, judged tasks, and the LLM-judge league.** The idea offers "judged task completion
  (BASALT/MineDojo)" as an alternative motive and calls a judged-task league "the first non-score
  coworld on the site". **The coordinator ruled it out of v1 and this note carries that ruling.**
  Explicitly out: find-a-cave / build-a-house / pen-the-animals style objectives, a fixed rubric, an
  LLM judge, a judge audit trail, and any per-episode score that is not a deterministic function of sim
  state. v1's score is the ObtainDiamond ladder, computed by the engine from the inventory and the
  placed blocks, and verifiable from the replay bytes by anyone. A judged league is a different scoring
  substrate — it needs a judge service, an audit format and an appeals story — and it is the obvious v2
  once the ladder league is ranking.
- **MineDojo's language-specified task suite.** Thousands of natural-language goals, the YouTube/wiki
  knowledge base, and MineCLIP-style learned reward are all out. They are a reward *model*, and this
  coworld deliberately has a reward *function*.
- **First-person rendering, pixel observations, and a camera to aim.** The idea's own "per-frame keys +
  camera — heavy" is the interface it names as impractical, and the starter's raycast FPV pipeline is
  deleted rather than repurposed. The seat gets the symbolic observation of §Decisions; the `#fpv` panel
  is reused as a **top-down** agent-view inset, not as a first-person view. A 3-D voxel world, block
  faces, block placement in six directions, and a continuous look vector are all v2 at the earliest.
- **Any Malmo / MineRL / MineDojo / Minecraft dependency, and bit-exactness with any of them.** Decided
  as a scoping rail before design and recorded in `docs/PORTING-MINECRAFT.md`: no upstream code is
  vendored, no upstream numbers are claimed as reproduced, and no score from this coworld is comparable
  to a published benchmark number. This coworld implements the problem, not the package.
- **Multiplayer.** `num_agents` is fixed at 1 in every variant and in the cert fixture. A shared world
  with two cogs mining the same seam is a different game (contested resources, griefing, a stealing
  mechanic) and would break the ladder's meaning — the ladder measures one policy's plan depth, not a
  race. It is also the axis `cogame-crafter` already declined for the same reason.
- **A survival layer.** No hunger, health, mobs, day/night, drowning, fall damage or tool durability
  (§Sim module → divergence 7). They are what `cogame-crafter` is about; adding them here would make
  the two coworlds measure the same thing twice and would dilute the one thing this game measures.
- **The rest of the Minecraft tech tree.** Redstone, enchanting, the Nether, obsidian, buckets, chests,
  armour, farming, animals, beds, boats, rails and every block not in §The game's twelve-block enum.
  Every one of them multiplies the recipe table, the block table and the viewer's tile bakes, and none
  of them changes what the ladder measures until a policy can reliably reach a diamond.
- **World shapes other than 4 × 32 × 32.** A deeper stack, a bigger level, or a variable level count
  would fork the viewer's camera arithmetic, the strata gauge and the generator's thresholds for no gain
  the idea asks for. Both variants share the world shape and differ only in clock and density.
- **Per-primitive LLM stepping.** The seat batches up to twenty primitives a turn under a deterministic
  driver (§Decisions, divergence 6). One call per tick would be 960 calls in a 720 s budget.
- **Scoring blocks mined, distance travelled, cells explored or time survived.** `speedBonus` is the
  tie-break and nothing more; `blocksMined`, `blocksPlaced`, `itemsCrafted`, `shaftsDug`, `cellsSeen`,
  `deepestLevel` and the ore counters are measured, recorded in `results`, shown on the endcard and
  drawn in the feed, and deliberately **not** in `scores` (§The game). Paying for blocks mined would let
  a policy farm the metric by mining and re-placing the same stone forever.
- **A live spectator pod.** `/global` broadcasts a status feed (the certifier requires it) but the
  hosted spectator experience is the static replay bundle only; no live pod viewer is declared.
- **Everything the starter had that this game does not.** Guns, aim, vision cones, raycast fog, the
  first-person renderer, paint, hills, hearts, flags, grenades, med kits, shields, barriers, trenches,
  perks, handicaps, lives, teams, four-team play, shouts, the fifteen paintball achievement ids,
  campaign mode, multi-game episodes, the procedural map generator, the map pool, the map editor and
  mapkit — all deleted, not disabled (§Sim module), and none of them return in v1.
