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

## C. Lava is rare under the generator the note specifies

The note's underground rule 2 is `C < 120` **and** a per-cell draw below
`lavaChance[z]`. Because `C` is the interpolated cave field over `0…1023`,
`C < 120` selects only the densest few per cent of rock, and the product with
a 12–45 ‰ draw yields, measured over 50 seeds:

| | `z = 2` | `z = 3` |
|---|---|---|
| `standard` | 0.06 cells | 0.34 cells |
| `deepcut` | 0.16 cells | 0.60 cells |

The generator is implemented **exactly** as specified — changing a threshold
would be a redesign, not an implementation. The consequence is that the
design's own test 26 ("the cert seed emits at least one `lava` event") is not
satisfiable by any scripted episode, so `tests/test_minecraft_engine.nim`
asserts everything else that test asks for and records this note in place of
the lava clause. The lava rules themselves are fully covered by
`tests/test_minecraft_sim.nim` (`dig_down`'s case 3 and `lava kills`) and by
the renderer fixture's lava-death endcard. **Retuning `C < 120` upward is the
one-line change that would make lava a live hazard**, and it is left to a
follow-up because it changes the game's difficulty.

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

## G. The certification fixture's seed is 8, not 42

The design note pins `seed: 42` for the certification fixture and asks that the
episode it produces reach at least seven rungs, descend to at least `z = 2` and
run at least 400 ticks, so the CI smoke replay always exercises the milestone,
new-depth and blocked paths and always outlasts the ten-second viewer soak.
Under the corrected 30-bit `mix64` (divergence H) seed 42 reaches six rungs;
seed 8 reaches **nine**, descends to `z = 2`, runs the full **960** ticks and
mines forty ore blocks. `tools/probe_seeds.nim` is the committed probe that
picked it and `tests/test_minecraft_engine.nim` asserts every one of those
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

## J. Four cog facings from one render

`tools/art/source/cog_sheet.png` is one nano-banana render of four Softmax
cogs in a miner's kit (head-lamp, pickaxe). The model drew them near
front-facing rather than truly top-down, so the four split sprites read as
four poses rather than four unambiguous headings; the cog's heading is also
carried by the DOM chrome (`ALPHA · y=32 · FACING EAST`) and by the agent-view
inset. A re-render with a stricter camera instruction is a cheap follow-up.
