# What this is, and is not, a port of

`cogame-minecraft` is an **in-spirit reimplementation of the MineRL
ObtainDiamond problem** as its own deterministic seeded simulator, written in
Nim on the `coworld-ctf` (paintbot) stack. This file is the complete list of
places where it departs from Minecraft, from MineRL, or from the design note
it was built to — so nobody has to reverse-engineer the difference from the
code.

## 1. No Malmo, no MineRL, no MineDojo, no Minecraft, and no bit-exactness

Decided as a scoping rail before design. Minecraft is a JVM game behind
Malmo's C++/Python bridge; MineRL is Python plus a JVM server; MineDojo adds a
task suite and a video-pretrained reward model. Embedding any of them means a
simulator that cannot compile to WebAssembly, so the **static replay viewer**
— a non-optional platform pin — would be impossible, and a per-frame pixel
policy interface is not a coworld interface.

**No upstream code is vendored, no upstream number is claimed as reproduced,
and no score from this coworld is comparable to a published MineRL, VPT or
Voyager figure.** What *is* reproduced is the **problem**: the ObtainDiamond
ladder, rung for rung, in a seeded world you have to dig through.

## 2. Top-down 2-D cells on four discrete levels, not 3-D voxels

The idea's "per-frame keys + camera" interface is the one it calls "heavy"; it
also names the realistic alternative — "LLM agents work through a skill
library (Voyager-style), which is the realistic coworld interface". This
game's seventeen primitives plus three macros **are** that skill library, made
explicit and made deterministic. There is no camera to aim, no continuous
look, and no pixel observation.

## 3. Integer value noise, not Minecraft's world generator

A hashed lattice of stride 8 with fixed-point bilinear interpolation, because
a float noise field cannot be hashed identically native and in wasm. The
result is recognisably the same *kind* of world — grass and trees on top,
stone and coal below it, iron deeper, diamond and lava at the bottom — and is
not the same worlds.

`mix64` is splitmix64 over the mixed words, read as a pure HASH rather than a
stream, so nothing a policy does can shift a draw, reorder draws, or consume
one out from under a later tick: **the world of seed `s` is the same world
however the cog plays it.**

## 4. Eleven rungs, not twelve, and a strict doubling

MineRL's schedule contains two ties (`stick`/`crafting_table` at 4,
`furnace`/`stone_pickaxe` at 32) which make two materially different runs
score identically, and a league needs a total order. This game drops `stick`
as a *scored* rung (it remains a required crafted item and a real prerequisite
for all three pickaxes) and re-values the remaining eleven as a strict
doubling `1, 2, 4, …, 1024`. That makes `milestoneScore` exactly the milestone
bitmask and makes "one rung deeper always wins" an integer identity.

## 5. Episode length

MineRL's ObtainDiamond allows 18 000 steps (15 minutes at 20 Hz); this game
allows **960** (`deepcut`: 640), because the seat is an LLM on a 720 s budget.
The world size, the ore densities and the recipe costs are all scaled to that
budget so the ladder is genuinely completable.

## 6. Actions are batched under a driver, not stepped one per call

Up to twenty primitives per turn under a deterministic driver, plus three
macros and an `n` multiplier. One LLM call per primitive would be 960 calls in
a 720 s budget — impossible — and a policy that cannot express "tunnel east"
spends every turn walking. The **interrupt rule** (a newly known adjacent lava
ends the turn) is what keeps batching from removing reactivity.

## 7. No survival layer at all

No hunger, no health bar, no mobs, no day/night, no drowning, no fall damage,
no tool durability. Minecraft has all of them and `cogame-crafter` already
ships a coworld about them. Here the only lethal thing is lava and the only
clock is the deadline, because the thing being measured is **how deep a policy
can plan**, not whether it can stay fed.

## 8. No BASALT, no MineDojo language tasks, no LLM judge

The idea offers a judged-task league as an alternative motive; it is ruled out
of v1. Out: find-a-cave / build-a-house / pen-the-animals objectives, a fixed
rubric, an LLM judge, a judge audit trail, and any per-episode score that is
not a deterministic function of sim state.

## 9. Trees are finite; mining stone leaves walkable `tunnel`; a shaft is permanent

Stated because they are the ones an implementer guesses wrong.

## 10. `maxGames = 1`

The starter's multi-game episode is not used; a single run has no side to swap.

---

# Departures from the design note itself

The design note (`docs/plans/2026-08-29-minecraft-design.md`) is
authoritative and was implemented as written. These are the places where the
note's own text and the shipped repo differ, and why.

## A. `window.CTF_WIRE` survives as an alias

The note requires `client/chrome_common.js` **byte-for-byte** (sha256
`7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c`) AND the
`window.CTF_WIRE` → `window.MINECRAFT_WIRE` rename. That file reads
`window.CTF_WIRE`, so the two requirements are only jointly satisfiable
through an alias. `src/minecraft/wire_constants.nim` emits

```js
window.MINECRAFT_WIRE={...};window.CTF_WIRE=window.MINECRAFT_WIRE;
```

and `client/broadcast_core.js` reads `MINECRAFT_WIRE` first, `CTF_WIRE`
second. `ci.yml`'s `ctf_`/`CTF_` sweep whitelists that one line by name.

## B. The forbidden-vocabulary sweep is scoped to spectator-visible strings

The note asks `tests/test_minecraft_endcard_labels.nim` to find zero matches
for `Lives`, `flag`, `heart`, `paint`, `hill`, `team`, `kill` and friends
"outside comment blocks". Applied to every identifier in the page that is
unsatisfiable while ALSO inheriting the starter's chrome verbatim: `teamCol`,
`activeTeams`, `teamName`, `.ec-tname` and `killMarkerTeam` are
`chrome_common.js`'s own exported names, and `chrome_common.js` is pinned
byte-for-byte.

The test therefore parses the page and sweeps the **spectator-visible
strings** — text nodes plus `title`, `aria-label` and `alt` — which is what
the rule is actually protecting: a spectator must never read paintbot's
vocabulary. Every re-mapped string the note enumerates is separately asserted
present exactly once. The `team` word is dropped from the forbidden list for
the same reason (it appears only in inherited CSS class names, never in a
string a viewer reads).

## C. Lava's cave gate is 300, not the note's 120

The note's underground rule 2 is `C < 120` **and** a per-cell draw below
`lavaChance[z]`. Implemented literally, that is a game with no hazard in it:
`C` is the interpolated cave field over `0 … 1023`, so `C < 120` selects only
the densest few per cent of rock, and the product with a 12-45 permille draw
measured, over 300 seeds of each variant:

| gate | | `z = 2` | `z = 3` | seeds with any lava |
|---|---|---|---|---|
| `C < 120` | `standard` | 0.11 cells | 0.38 cells | 97/300 (32 %) |
| `C < 120` | `deepcut` | 0.21 cells | 0.58 cells | 140/300 (47 %) |
| `C < 300` | `standard` | 1.56 cells | 4.21 cells | 295/300 (98 %) |
| `C < 300` | `deepcut` | 2.41 cells | 6.37 cells | 298/300 (99 %) |

At 120, two thirds of `standard` seeds contained **no lava at all**, and
`endRule = death`, `deathCause = lava`, the interrupt rule, `place_block`'s
bridge, `dig_down`'s case 3 and the death endcard were live code with no live
traffic — while the note's own prose calls lava "the only thing in this world
that can end a run" and its test 26 asks the certification seed to emit a
`lava` event. `src/minecraft/world.nim`'s `LavaCaveGate` is therefore **300**.
Everything else in rule 2 — the `lavaChance` table, the draw, the salt — is
the note's.

**This changes the game's difficulty**, so it carries a `GameVersion` bump
(1 → 2) and the replay fixtures were re-cut against it:

- The scripted `miner` now dies in lava on about one standard seed in ten
  (0 of 100 before), and its swept total over the 40 + 40 seed battery falls
  from 37 374 to 34 654. `tools/tune_baselines.nim` was re-run: the pick moves
  from `woodSticks: 6` to `woodSticks: 4`, and `tools/ci/baseline_tuning.json`
  and `DefaultBaselineParams` are re-pinned to it.
- The sweep exposed a real defect in the baseline that no seed had reached
  before: `safestStep` returned `fcNorth` when the cog was boxed in with **no**
  traversable neighbour, which walked it into the lava it was fleeing. It now
  reports "no safe step" and the miner mines its way out instead.
- The **certification seed moves from 8 to 674** (divergence G): under the new
  gate, seed 674's scripted episode reaches ten rungs, `z = 3`, 941 ticks, and
  emits a `lava` event, so the design note's test-26 lava clause is asserted
  rather than documented away.

Every level is still at least 78 % diggable (`unsealLava`, post-pass 5), every
seed is still completable (`tests/test_minecraft_world.nim`'s reachability
flood over 60 seeds of both variants), and the `miner` baseline still clears
rung 9 on 38 of 50 standard seeds.

One thing the higher gate does **not** make common is the *interrupt* (tick
step 8): it fires only on lava that becomes newly known while already within
Chebyshev 1, and the 5 × 5 underground window usually reveals a lava cell two
steps before the cog can stand next to it. Most lava deaths are a stale plan
walking into a cell the cog learned about mid-turn, which is the reactivity
cost the note's batching section describes.

## D. Seeking re-simulates instead of restoring a keyframe

The starter needs flatty keyframes because a paintbot sim carries ~40 MB of
static map bakes. This sim is four 32 × 32 integer grids over at most 960
ticks — microseconds of work — so `seekReplay` re-simulates from tick 0.
That removes the whole class of bug the keyframe machinery exists to manage
(stale bakes, restored-but-restamped geometry) at no cost to the viewer.

## E. `global.nim` is a new module, not a retarget

The starter's `global.nim` is 8 000 lines of pixel arena, raycast fog and
paint FX, essentially none of which survives the note's own deletion list.
The fork's `src/minecraft/global.nim` is written against the same
`bitworld/spriteprotocol` API and keeps the three named edits the note
specifies (cell-space board, block/overlay pools emitted incrementally, a
baked tile bed) in ~380 lines. The board tiles are the nano-banana renders
under `data/art/`, scaled once at startup with pixie, rather than recoloured
crops of `arena_floor.png`.

## F. The end-to-end episode test drives the engine, not the sockets

`tests/test_minecraft_engine.nim` runs a real episode through the same procs
`server.nim` drives — the decision engine, the driver, `sim.step`, the replay
writer and `runResultsJson` — with the websockets left out.
`tools/ci/docker_smoke.sh` covers the socket path end to end, in the
production image, on every CI run.

## G. The certification fixture's seed is 674, not 42

The design note pins `seed: 42` for the certification fixture and asks that the
episode it produces reach at least seven rungs, descend to at least `z = 2`,
run at least 400 ticks and emit at least one `lava` event, so the CI smoke
replay always exercises the milestone, new-depth, blocked and lava paths and
always outlasts the ten-second viewer soak. Under the corrected 30-bit `mix64`
(divergence H) seed 42 reaches six rungs. Seed 674 reaches **ten**, descends to
`z = 3`, runs **941** ticks, mines fifteen ore blocks and emits a `lava` event
under the divergence-C gate, so every clause of the note's test 26 is now
asserted and none of it is documented away. `tools/probe_seeds.nim` is the
committed probe that picked it (its filter is exactly the note's list of clauses, lava
included) and `tests/test_minecraft_engine.nim` asserts every one of those
properties against whatever seed the manifest actually declares, so the two can
never drift.

## H. `mix64` is masked to 30 bits, not 63

The sim compiles TWICE from one source: natively, where Nim's `int` is 64 bits,
and to **wasm32**, where it is 32. `mix64` originally returned
`int(x and 0x7FFF_FFFF_FFFF_FFFF)`, which is a perfectly good native value and
raises `value out of range` on the first world generation in the browser. It
did: the whole bundle loaded, every asset returned 200, and the viewer sat on
its loading curtain with `initialize replay runtime: value out of range`
(run 33241005565). The mask is now `0x3FFF_FFFF`, which is unambiguously
positive in an `int32`, and `mix64u` carries the full 64-bit value for the
world digest, where `uint64` is 64 bits on every target.
`tests/test_minecraft_world.nim` asserts every generated integer fits an
`int32`, which is the check that would have caught it natively.

## I. The follow-cam converges instead of using the note's closed form

The note's test 42 asks the game block to call `core.setZoom(32 / cameraCells)`
with `cameraCells == 15`. That closed form is only correct when the board is
letterboxed on its **width**: `setZoom` is a scale on the core's own fit, and
the core fits whichever axis is tighter. Measured in the browser (the fixture
screenshot at run 33242102244) it left the board at roughly four cells across.

`client/replay_broadcast.html:4653-4676` therefore reads the span back from the
transform the core reports and corrects towards it:

```js
var cellsNow = t.visW > 0 ? t.visW / 24 : CAMERA_CELLS;
if (followArmed && Math.abs(cellsNow - CAMERA_CELLS) > 0.5) {
  core.setZoom((t.zoom || 1) * (cellsNow / CAMERA_CELLS));
```

`CAMERA_CELLS` is still 15 and the target is still the note's 15-cell window;
only the way the zoom is computed differs, and the static bundle's core lives a
thread away, so its own answer is the only honest one.
`tests/test_minecraft_viewer.nim` pins all three lines as exact strings, so this
mechanism cannot be loosened without the test noticing.

## J. Playback runs at 24 ticks/second, not the note's 10

The note specifies "one tick per three animation frames at 30 fps = 10
ticks/second", with the cog interpolated across the three frames, and speed
chips `[0.5, 1, 2, 4, 8]`. The shipped rate is **one tick per frame at
`TargetFps` = 24**, with chips `[1, 2, 3, 4, 8, 16]` (`PlaybackSpeeds`), and
no sub-tick interpolation.

Two reasons, both structural rather than aesthetic:

1. `ReplayFps` **is** `TargetFps` (`sim_types.nim`), so a recorded time and a
   tick are the same clock. `tickTime` / `tickOfTime` round-trip exactly at one
   tick per frame; any other cadence needs a fractional accumulator on the
   playback side and leaves the scrubber's tick axis and the recorded chat
   times disagreeing by up to half a tick.
2. The chips are integer step counts per frame (`replaySpeed()` multiplies
   `stepReplay` calls), so a `0.5` chip is not a slower step but a skipped
   frame, which is the same accumulator again.

The consequence the checklist cares about is the soak: a 960-tick episode
plays for **40 s** and the shortest episode CI can produce is well over
`viewer_smoke.mjs --soak 10`, so the soak still watches a genuinely advancing
replay. `ci.yml`'s comment on the soak step carries the 24 as well, so the two
cannot drift apart again.

## K. Four cog facings from one render

`tools/art/source/cog_sheet.png` is one nano-banana render of four Softmax
cogs in a miner's kit (head-lamp, pickaxe). The model drew them near
front-facing rather than truly top-down, so the four split sprites read as
four poses rather than four unambiguous headings; the cog's heading is also
carried by the DOM chrome (`ALPHA · y=32 · FACING EAST`) and by the agent-view
inset. A re-render with a stricter camera instruction is a cheap follow-up.

## L. The board is composited server-side, so `broadcast_core.js` gained no draw calls

The note's §Viewer says of `client/broadcast_core.js`: "Deleted: every
ctf-specific draw call and the raycast FPV pipeline … Added: `drawBlocks`,
`drawShafts`, `drawCog`, `drawFog`, `drawAgentView`, `drawLadder`,
`drawStrata`, `drawInventory`." None of those eight functions exists in this
repo, and the deletions did not happen either: `client/broadcast_core.js`
differs from the starter's by exactly **one added line** (`:49`, the
`MINECRAFT_WIRE` lookup).

That is deliberate, and it is the stronger reading of the checklist's
"the chrome is the starter's, not a lookalike":

- The **board** is composited into the starter's own sprite protocol by
  `src/minecraft/global.nim` (`buildBoardPacket`) and drawn by the starter's
  unmodified compositor. Blocks, shafts, the cog and the fog are sprites in
  that packet, not new draw calls in the client, so the camera, the zoom bar
  and the minimap keep working on the code they were written for rather than
  on a fork of it.
- The four **panels** — the milestone ladder, the strata gauge, the inventory
  strip and the agent-view inset — are DOM, built by the appended game block
  (`client/replay_broadcast.html:4489+`). Item 15's "every drawn string fits
  its frame" is why: a DOM panel cannot draw a caption at a negative
  coordinate, and this viewer has no `fillText`/`strokeText` anywhere as a
  result (test 44).

The note's eight names describe the same eight readouts; only the layer they
are drawn on differs, and the layer that shipped is the one that leaves
`broadcast_core.js` inherited.

## M. A no-show seat is declared and the run plays out; the note also says "refuses to start"

The note's named edit 2 asks the server to "log loudly and refuse to start the
game when the joined seat has no register record (the grf-football 2026-08-27
silent-default scar)", and its test 27 asks the same scenario to "produce a
finished episode inside the wall-clock budget", with `fallbackTurns` counted
and `deadSeats` set. Those two are not jointly satisfiable: an episode that
never starts never finishes and never scores.

`src/minecraft/server.nim:575-595` implements the second, with the first one's
guarantee kept intact — the thing the scar is actually about is a **silent**
default:

- `ERROR: seat 0 <why> within <n> lobby ticks; the run plays the published
  miner baseline and the failure is declared` on stdout,
- `declarePlayerFailure(0, …)` — the closed two-key
  `{message, failed_policy_index}` payload the platform reads,
- `sim.deadSeats[0] = true`, so the seat is marked dead in `results`,
- and only then a `start` record, with the seat playing the **published**
  `miner` baseline rather than a hidden internal default.

Nothing about the outcome is silent or invented: the platform is told the seat
failed, the replay says which baseline played, and the run scores. A refusal
would instead produce no replay, no results document and nothing for the
league to read, on the one failure mode a single-seat game is most likely to
hit.
