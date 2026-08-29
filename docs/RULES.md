# Rules

One cog stands in the middle of a green field with nothing in its hands.
Underneath it are three more floors of the world it cannot see: **stone**,
then **iron depth**, then **diamond depth**. There is nothing alive down
there, nothing hunting it, nothing to eat and nowhere to sleep. There are
eleven things it has never done, in a fixed order, and each one needs the one
before it:

**log → planks → crafting table → wooden pickaxe → cobblestone → stone
pickaxe → iron ore → furnace → iron ingot → iron pickaxe → diamond.**

That is MineRL's ObtainDiamond ladder, rung for rung. The cog has **960
ticks**. When they are gone the run stops wherever it stands, and the only
thing the league reads is **how far up the ladder it got, and how fast**.

## The world

`levelCount = 4`, `levelSize = 32`. Four 32 × 32 grids stacked in `z`, each
indexed `(x, y)` with `x` the column `0 … 31` (west → east) and `y` the row
`0 … 31` (north → south); `(0, 0)` is the north-west corner of every level.

| `z` | Label | What is down there |
|---|---|---|
| 0 | `y=64 (surface)` | grass, sand, water, oak trees, the odd stone boulder |
| 1 | `y=48 (stone)` | stone, coal ore, natural caves |
| 2 | `y=32 (iron depth)` | stone, iron ore, coal ore, caves, lava |
| 3 | `y=12 (diamond depth)` | stone, diamond ore, iron ore, caves, more lava |

The outermost ring of every level is **bedrock** — impassable, unmineable,
unplaceable — so the cog can never leave the world. `cellsTotal` is 4096.

**A cell holds exactly one block.** `tier` is the lowest pickaxe tier that can
mine it (`0` = bare hands, `1` = wooden, `2` = stone, `3` = iron, `—` = never).

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

Two more glyphs are **overlays**: `v` means a shaft goes DOWN from this cell,
`^` means one goes UP. `@` is the cog and `?` is a cell it has never seen.
Those seventeen glyphs are the whole vocabulary.

**Shafts are the only vertical connection.** There is no free falling, no
ladders, no climbing a wall. You go down where you cut a hole and you come up
the same hole.

## Sight

The view is the `(2r+1)²` square centred on the cog **on its current level**,
world-oriented, no occlusion and no line of sight. `r = 5` at the surface (an
11 × 11 window: the sky is open) and `r = 2` underground (5 × 5: it is dark
down there). **A level the cog has never descended to is entirely `?`** — the
diamonds are under a floor you cannot see through.

## Recipes

| Recipe | Costs | Yields | Also needs |
|---|---|---|---|
| `craft_planks` | 1 log | 4 planks | — |
| `craft_sticks` | 2 planks | 4 sticks | — |
| `craft_wooden_pickaxe` | 3 planks + 2 sticks | wooden pickaxe | a table within 1, same level |
| `craft_stone_pickaxe` | 3 cobblestone + 2 sticks | stone pickaxe | a table within 1, same level |
| `craft_iron_pickaxe` | 3 iron ingots + 2 sticks | iron pickaxe | a table within 1, same level |
| `smelt_iron` | 1 raw iron + 1 coal | 1 iron ingot | a furnace within 1, same level |
| `place_crafting_table` | 4 planks | a table | faces grass, sand or tunnel |
| `place_furnace` | 8 cobblestone | a furnace | faces grass, sand or tunnel |
| `place_block` | 1 cobblestone | stone | faces lava or water |

Tools never break. Inventory stacks cap at 64. Crafting an already-owned
pickaxe is a free no-op.

## Lava

Walking into lava kills the cog instantly and ends the run. **Digging down
ONTO lava does NOT kill** — the floor breaks, the cog stays put, and the cell
below becomes permanently known. That asymmetry is deliberate: the seat cannot
see through the floor, so a blind descent must never be an instant loss, while
a step into a cell it *can* see is a policy error. Lava becoming newly known
within one cell of the cog **ends the turn** and throws the rest of the plan
away — the game's only reactivity, and the only thing worth being reactive to.

## Scoring

```
milestoneScore    = sum over unlocked rungs i of 2^i        (0 .. 2047)
milestonesReached = popcount(milestoneUnlocked)             (0 .. 11)
deepestTick       = the tick the DEEPEST unlocked rung lit
speedBonus        = 0 if nothing unlocked else (maxTicks - deepestTick)
scores[0]         = 1000 * milestoneScore + speedBonus
```

Higher is better and every term only ever adds: the minimum is `0`, the
maximum `1000 × 2047 + 959 = 2 047 959`. `milestoneScore` is literally the
eleven-bit milestone mask read as an integer, so **reaching one rung higher
beats every possible combination of the rungs below it** — an integer
identity, not a convention. `maxTicks` is always below 1000, so `speedBonus`
can never reach one rung's worth and is purely the tie-break.

`results.win[0]` is `milestonesReached >= parMilestones` (6 in `standard`, 5
in `deepcut`) and `results.winner` is `0` when that is true, `null` otherwise.

**Measured but never scored:** blocks mined, blocks placed, items crafted,
iron smelted, shafts dug, bridges placed, cells seen, deepest level, ticks per
level, ore counters, interrupts, primitives executed, actions dropped, macros
unreachable, replies repaired. Paying for any of them would let a policy farm
the metric by mining and re-placing the same stone forever.

## Ending

The episode ends at the first of: the **diamond** (rung 11 — the run stops in
triumph, which also maximises the speed bonus), **death in lava**, the **turn
cap** (48 turns — the normal way a run ends), the **tick cap** (960, an
independent guard), or the engine's **wall-clock stop**.

`results.endRule` is `diamond | death | turnCap | tickCap | wallClock | fault`.
`results.reason` is the platform's closed enum: **`complete`** for the first
four (running out of ticks is the game working exactly as designed),
**`deadline`** for the wall-clock stop, and **`fault`** for an unrecoverable
server error, which is always a defect.

## Variants

| Variant | `maxTurns` | `maxTicks` | lava ‰ (z2/z3) | coal ‰ (z1/z2) | iron ‰ (z2/z3) | diamond ‰ (z3) | `parMilestones` |
|---|---|---|---|---|---|---|---|
| `standard` | 48 | 960 | 12 / 30 | 180 / 80 | 140 / 110 | 70 | 6 |
| `deepcut` | 32 | 640 | 18 / 45 | 270 / 120 | 210 / 165 | 105 | 5 |

Nothing else differs: the ladder, the recipes, the tiers, the action set and
the level structure are identical, so `milestoneScore` means the same thing in
both.

## A worked results document

```json
{
  "names": ["daveey"], "aliases": ["Alpha"], "scores": [255648],
  "win": [true], "winner": 0, "reason": "complete", "endRule": "turnCap",
  "variant": "standard", "seed": 1734029581,
  "milestoneIds": ["log","planks","crafting_table","wooden_pickaxe",
                   "cobblestone","stone_pickaxe","iron_ore","furnace",
                   "iron_ingot","iron_pickaxe","diamond"],
  "milestonePoints": [1,2,4,8,16,32,64,128,256,512,1024],
  "milestoneUnlocked": [true,true,true,true,true,true,true,true,false,false,false],
  "milestoneTick": [14,17,19,20,21,96,288,312,-1,-1,-1],
  "milestonesReached": 8, "milestonesOf": 11, "milestoneScore": 255,
  "parMilestones": 6, "deepestMilestone": "furnace", "deepestTick": 312,
  "speedBonus": 648, "deathCause": "none", "deepestLevel": 2,
  "ticksPerLevel": [21, 75, 864, 0], "cellsSeen": 412, "cellsTotal": 4096,
  "blocksMined": 184, "blocksPlaced": 2, "itemsCrafted": 9, "ironSmelted": 0,
  "shaftsDug": 2, "bridgesPlaced": 1, "coalMined": 4, "ironOreMined": 2,
  "diamondsMined": 0, "invLog": 0, "invPlanks": 1, "invStick": 2,
  "invCobblestone": 6, "invCoal": 4, "invRawIron": 2, "invIronIngot": 0,
  "invDiamond": 0, "toolsOwned": ["wooden_pickaxe","stone_pickaxe"],
  "interrupts": 3, "primitivesExecuted": 951, "actionsDropped": 2,
  "macrosUnreachable": 1, "repliesRepaired": 0, "finalTick": 960,
  "turnsPlayed": 48, "policyKinds": ["llm"], "llmTurns": [47],
  "fallbackTurns": [1], "deadSeats": [false], "stopDetail": ""
}
```

Eight unlocked rungs give `1+2+4+8+16+32+64+128 = 255`; the deepest is
`furnace` (index 7) at tick 312, so `speedBonus = 960 − 312 = 648` and
`scores[0] = 1000 × 255 + 648 = 255 648`; `8 ≥ 6` so `win[0]` is true and
`winner` is `0`; and `ticksPerLevel` sums to `960 = finalTick`.
`tests/test_minecraft_engine.nim` asserts all seven of those identities on
every episode it runs.
