# cogame-minecraft

**One cog, four stacked levels, and the MineRL ObtainDiamond ladder.**

A single-agent Coworld. One cog stands in the middle of a seeded blocky world
with nothing in its hands. Underneath it are three more floors it cannot see:
stone, iron depth, diamond depth. It has 960 ticks to climb eleven rungs —

> log → planks → crafting table → wooden pickaxe → cobblestone → stone
> pickaxe → iron ore → furnace → iron ingot → iron pickaxe → **diamond**

— and every rung is worth **double every rung beneath it put together**, so
the score is exactly how deep it got, with speed as the tie-break. Nothing is
hunting it. It never eats, drinks or sleeps. The only lethal thing in the
world is lava, and the only pressure is the clock.

The cog sees 11 × 11 on the surface and only **5 × 5** underground, and a
level it has never descended to is entirely `?`. **You cannot see through the
floor.** Wood exists only on the surface, so the six turns you spend walking
back up for forgotten planks are six turns you do not get back.

This is an **in-spirit reimplementation** of the MineRL ObtainDiamond problem
as its own deterministic seeded simulator. No Malmo, no MineRL, no MineDojo
code is vendored, and no score here is comparable to a published benchmark
number — see [`docs/PORTING-MINECRAFT.md`](docs/PORTING-MINECRAFT.md).

## Docs

* [`docs/RULES.md`](docs/RULES.md) — the world, the blocks, the recipes, the
  scoring formula, the end conditions, the two variants.
* [`docs/ACTIONS.md`](docs/ACTIONS.md) — the seventeen primitives, the three
  macros, the reply schema and its caps, and the full observation.
* [`docs/MILESTONES.md`](docs/MILESTONES.md) — the eleven rungs, why the
  values double, and what the tick budget buys.
* [`docs/PORTING-MINECRAFT.md`](docs/PORTING-MINECRAFT.md) — every documented
  divergence, from Minecraft and from the design note.
* [`docs/PROTOCOL.md`](docs/PROTOCOL.md) — the wire protocol, the routes, the
  registration message and the replay format.

## A policy is just a prompt

Both champions are LLM prompt policies; both fillers are scripted baselines;
**one image, switched by env**.

```bash
coworld upload-policy coworld-minecraft:latest --name my-minecraft \
  --run /bin/minecraft-player \
  --secret-env PLAYER_PROMPT="Get to the diamond. Nothing else is worth a tick."
```

| Env | Effect |
| --- | --- |
| `PLAYER_PROMPT` | this seat is an **LLM seat**; the text is your whole strategy |
| `PLAYER_SCRIPTED=miner` | the published deterministic baseline — and the server-side fallback |
| `PLAYER_SCRIPTED=scrounger` | the reactive control: no memory, no pathfinding, no ore targeting |
| `PLAYER_POLICY_LABEL` | a free label for the replay's `register` record |

A seat that sets neither is `miner`.

**The LLM call is made by the GAME container, not the player container** —
that is the only container the platform injects the `anthropic_api_key`
coworld secret into, and it is what makes the recorded primitive log
reproducible with no network in the loop. The player process connects,
registers, and then only acknowledges frames.

## Degrade, never hang

Every wait is bounded. One request per turn, `attempt1Ms = 6000`; one retry,
`retryMs = 3000`; a monotonic `turnBudgetMs = 9500` around the whole turn;
`turnSpacingMs = 2600` pinning the steady state at 23 req/min against the
sidecar's 30/min cap; a rolling 60 s rate guard; a budget guard that switches
the LLM off the moment two more full turns would not fit; and the engine's own
`wallClockBudgetSeconds = 660` stop. Typical episode: **199 s**. Absolute
worst case: **577 s**. The platform's budget is 1200 s and the pin is 60 % of
it (720 s).

On a second failure the turn's plan becomes the **`miner`** scripted plan —
the same proc the published baseline uses, imported, never duplicated — and a
`fallback` record names the cause. **No failure mode leaves the cog without an
action:** the tick loop always has a primitive, else `noop`, which is a legal
state that costs a tick and nothing else.

## Watching it

The replay is a **static wasm bundle**, never a pod:
`tools/build_replay_viewer.sh` compiles the *same* sim module to WebAssembly
through the pinned `emscripten/emsdk:4.0.15` container and bundles it with the
inherited `coworld-ctf` broadcast chrome. The viewer re-derives every frame in
the browser from the replay's seed, its per-turn plans and its per-tick hash
chain; nothing is contacted except S3 for the file.

What you see: the 15-cell follow-cam over the level the cog is on (the board
is 32 × 32 cells and the level swaps with a wipe when the run goes deeper),
the **milestone ladder** lighting rung by rung in the left gutter, the
**strata gauge** showing every shaft it has cut and every ore it has seen at
its true depth, the cog's own 5 × 5 window as an inset, and the feed where the
LLM narrates. The scrubber carries labelled, clickable beats for exactly five
kinds: `milestone`, `newdepth`, `death`, `fallback`, `end`.

## Layout

| Path | What |
| --- | --- |
| `src/minecraft/` | the sim: `world` (generation, BFS, visibility), `agent` (the seventeen primitives), `milestones`, `sim_state` (the tick loop and the hash), `roster` (results), `observe`, `driver`, `baselines`, `decide`, `llm`, `replays`, `broadcast`, `global`, `server` |
| `src/minecraft.nim` | the game entrypoint → `/bin/minecraft` |
| `src/minecraft_player.nim` | the thin seat registrar → `/bin/minecraft-player` |
| `client/` | the inherited broadcast chrome plus the appended game block |
| `replay-viewer/` | the wasm entry, the emscripten flags and the static shell |
| `data/art/` | the nano-banana board sprites (source sheets + split script in `tools/art/`) |
| `tests/` | the Nim suite `ci.yml` runs in debug AND release |
| `tools/ci/` | the docker smoke, the viewer smoke, the renderer fixture and the policy set |

## Building and testing

The repo needs Nim 2.2.4 and the `nimby.lock` package tree; `ci.yml` is the
harness of record.

```bash
nimby use 2.2.4
nimby --global sync nimby.lock
nim r --path:src tests/test_minecraft_sim.nim        # any one test file
docker build --platform=linux/amd64 -t coworld-minecraft:ci .
./tools/ci/docker_smoke.sh coworld-minecraft:ci      # one real episode
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
node tools/ci/viewer_smoke.mjs --bundle dist/static-replay-viewer \
  --replay dist/smoke/*.replay --soak 10 --strict-text-bounds
```

`tools/replay_summary.py` prints one strict-UTF-8 JSON object for any
`.replay` using nothing but the Python 3 standard library.

## Licence

MIT. Forked from [`Metta-AI/coworld-ctf`](https://github.com/Metta-AI/coworld-ctf).
