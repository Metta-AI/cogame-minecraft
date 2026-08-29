# The ObtainDiamond ladder

MineRL's ObtainDiamond ladder, rung for rung, in the canonical order. This
ordering is `results.milestoneIds`, the order of the viewer's ladder panel,
and the order of the `locked` list in the observation. Each rung unlocks
**once**, permanently, the tick its predicate over **sim state** first becomes
true, and is never revoked.

**No rung is ever a self-report.** The predicate is evaluated by the engine
against the inventory, the tool flags and the placed blocks, every tick. That
is the idea's "milestone verification from game state", implemented literally.

| # | id | Points | Unlocks when |
|---|---|---|---|
| 1 | `log` | 1 | `log ≥ 1` |
| 2 | `planks` | 2 | `planks ≥ 1` |
| 3 | `crafting_table` | 4 | a crafting table exists anywhere in the world |
| 4 | `wooden_pickaxe` | 8 | the wooden pickaxe is owned |
| 5 | `cobblestone` | 16 | `cobblestone ≥ 1` |
| 6 | `stone_pickaxe` | 32 | the stone pickaxe is owned |
| 7 | `iron_ore` | 64 | `raw_iron ≥ 1` |
| 8 | `furnace` | 128 | a furnace exists anywhere in the world |
| 9 | `iron_ingot` | 256 | `iron_ingot ≥ 1` |
| 10 | `iron_pickaxe` | 512 | the iron pickaxe is owned |
| 11 | `diamond` | 1024 | `diamond ≥ 1` |

## Why the values double

`milestoneScore` is literally the **eleven-bit milestone mask read as an
integer** — bit `i` is rung `i`. Because `2^k > 2^0 + … + 2^(k-1)`, **reaching
one rung higher beats every possible combination of the rungs below it**. A
cog that reaches the iron pickaxe and nothing else outranks a cog that
collected every rung up to the iron ingot. That is an integer identity, not a
convention, and it is what makes the ladder a total order a league can rank.

MineRL's own reward schedule is `log 1, planks 2, stick 4, crafting_table 4,
wooden_pickaxe 8, cobblestone 16, furnace 32, stone_pickaxe 32, iron_ore 64,
iron_ingot 128, iron_pickaxe 256, diamond 1024`. It contains two ties
(`stick`/`crafting_table` at 4, `furnace`/`stone_pickaxe` at 32) which make
two materially different runs score identically. This game drops `stick` as a
*scored* rung — it is still a required crafted item and a real prerequisite
for all three pickaxes — and re-values the remaining eleven as a strict
doubling. See [`PORTING-MINECRAFT.md`](PORTING-MINECRAFT.md) divergence 4.

## The tie-break

`speedBonus = maxTicks - deepestTick` where `deepestTick` is the tick the
**deepest** unlocked rung lit. `maxTicks` is 960 (`standard`) or 640
(`deepcut`), both below 1000, so the bonus can never reach one rung's worth.
It rewards reaching the same rung earlier, and nothing else.

## What the tick budget buys

A perfect line through the ladder costs roughly:

| Stretch | Ticks | Running total |
|---|---|---|
| walk to a tree, 2 × `mine` (6 logs), 3 × `craft_planks`, 2 × `craft_sticks`, table, wooden pickaxe | ~19 | 19 |
| 1 × `dig_down` (the floor under spawn is forced stone, so this is also the cobblestone rung) | 1 | 20 |
| ~22 ticks tunnelling on `y=48` for 12 cobblestone and 3 coal, + table + stone pickaxe | ~25 | 45 |
| 1 × `dig_down` + ~40 ticks tunnelling on `y=32` for iron, + furnace + table + 3 × `smelt_iron` + iron pickaxe | ~50 | 95 |
| 1 × `dig_down` + ~60 ticks of lattice tunnelling on `y=12` to find a vein | ~65 | ~160 |

`standard`'s 960 ticks is therefore ~6× a perfect line and ~3× a competent
one; `deepcut`'s 640 is ~4×. Tight enough that route choice decides the run,
loose enough that the diamond is genuinely reachable — the shipped `miner`
baseline cuts one on a minority of seeds and reaches the iron ingot on most.
