# minecraft wire protocol — Sprite v1 plus the minecraft registration

Both the player endpoint (`/player`) and the global/spectator endpoint
(`/global`, `/replay`) speak
[Sprite v1](https://github.com/Metta-AI/bitworld/blob/master/docs/sprite_v1.md).
This document lists everything this coworld adds or changes relative to that
base document; anything not mentioned here matches Sprite v1 exactly. Game
semantics live in [`RULES.md`](RULES.md) and [`ACTIONS.md`](ACTIONS.md).

**The seat sends no inputs.** Every primitive the cog runs is computed inside
the GAME container, because that is the only container the platform injects
the `anthropic_api_key` coworld secret into, and because keeping the decision
layer server-side is what makes the recorded primitive log reproducible with
no network in the loop. The player container is therefore deliberately thin:
it connects, registers, and then only acknowledges frames.

## Routes

| Route | Method | What it is |
| --- | --- | --- |
| `/healthz` | GET | `200 healthy`. Kept answering for a bounded grace after the artifacts are written. |
| `/player?slot=N&token=T` | GET (websocket) | The seat. The socket is **refused** unless the token matches the seat: the certifier probes this route with a bad token. |
| `/global` | GET (websocket) | The spectator board + chrome stream. Rejects any request carrying player credentials. |
| `/replay` | GET (websocket) | The same stream in replay mode. |
| `/client/replay`, `/clients/replay` | GET | The DEVELOPER replay page. **Never declared to the platform** — the hosted replay is the static wasm bundle and nothing else. |
| `/client/player`, `/client/global` | GET | The generic bitworld client pages. |
| `/client/art/...`, `/client/font.ttf`, `/client/cog_avatar.png` | GET | Static viewer assets. |

`Ping` frames are answered with `Pong`, verbatim. There is deliberately **no**
`kind != TextMessage` guard on the websocket handler: the seat's registration
arrives as a **binary** Sprite v1 frame and such a guard would drop it.

## Registration: ONE Sprite v1 chat message, and it is a secret

The seat's `0x81` chat frame is read as its registration and is **consumed**:
it is never applied as in-game speech and never written to the replay chat
stream. The prompt is a secret.

```json
{"type": "register",
 "prompt": "<PLAYER_PROMPT, or an empty string>",
 "scripted": "miner" | "scrounger" | null,
 "policy": "<a free label>"}
```

* `prompt` is rune-truncated at **4000 runes** (`MaxPromptRunes`), `policy` at
  **64 runes**.
* A non-empty `prompt` makes the seat an **LLM seat**. Otherwise `scripted`
  names a baseline; a seat that sets neither is `miner`.
* The server writes a **redacted** `register` record into the replay — the
  policy label, the kind and the baseline, never the prompt.
* **Registration is re-sent, not sent once.** The lobby sends frames to a
  socket before it has been admitted, so a single registration can land while
  the seat has no index yet. The server HOLDS an unappliable registration and
  the reference player re-sends it for the first ~10 s of frames. Registering
  twice is harmless.
* The server **logs loudly** and reports a player failure if the joined seat
  never sends a register record; it then plays the published `miner` baseline
  rather than silently defaulting.

## Player Ready (`0x85`)

Supported and legitimate here in a way it is not for an ordinary player
client: this seat sends **no inputs at all**, so the dead-reckoning hazard
Sprite v1 warns about cannot arise, and a `fastMode` server can advance as
soon as the seat acknowledges the frame.

## Player failure

A seat that never joins, or joins and never registers, is reported once to
`COGAME_PLAYER_FAILURE_URI` with the platform's **closed** payload — exactly
two keys, nothing else:

```json
{"failed_policy_index": 0, "message": "..."}
```

The episode then plays out on the `miner` baseline and still produces a
complete results document. A no-show never poisons the whole episode
unattributed.

## The global stream

The board rides the binary sprite channel: one map layer, one 24 px tile
sprite per block, one cog sprite per facing, two fog washes, and per-cell
objects emitted as a **diff** against the viewer's last frame.

The broadcast **chrome** rides the SAME binary channel, as the label of a
reserved never-drawn 1×1 sprite (`BroadcastChromeSpriteId = 4090`). That is
the only channel that survives a hosted replay: the legacy opt-in
`TextMessage` path never routes the client→server `hud:on` through the
recorded stream, so hosted the HUD froze at its DOM defaults while the board
played. The generic bitworld client simply ignores an unknown sprite id.

Viewer input comes back as Sprite v1 client messages; whole-string commands
(`s:<tick>`) are intercepted before the char-by-char transport path so a
multi-digit tick is never mangled into speed keystrokes.

## The Coworld contract

In: `COGAME_CONFIG_URI`. Out: `COGAME_RESULTS_URI`,
`COGAME_SAVE_REPLAY_URI`, `COGAME_PLAYER_FAILURE_URI`, `COGAME_EVENTS_URI`.
Replay mode: `COGAME_LOAD_REPLAY_URI` plus `/client/replay`. Host and port
come from `HOST`/`PORT` or `COGAME_HOST`/`COGAME_PORT`.

## The replay

The binary `COWLDMCR` format: magic, format version, `gameName` `minecraft`,
`gameVersion`, the resolved config JSON, then the record stream —

| Record | Carries |
| --- | --- |
| join | the seat's REAL policy name, its slot and its token |
| input | **one primitive per tick** — this game's entire input log |
| hash | one `gameHash` per tick — the integrity chain the viewer re-checks |
| chat | `register` / `directive` / `fallback` / `budget_guard` / `start` / `turnend` / `stop` / `result` |

`start`, `turnend` and `stop` are **control** records applied by the SAME proc
on record and on playback: a wall-clock fact cannot be re-derived from sim
state, so the stop is written rather than inferred.

Everything the viewer needs is in the bytes. The world generator is code,
compiled into both the binary and the wasm module, and the replay carries the
seed, the variant and every rule constant — so the viewer reconstructs all
four levels, every ore and every lava pocket with no fetch.

`tools/replay_summary.py` (Python 3 stdlib only) prints one strict-UTF-8 JSON
object for any `.replay`.
