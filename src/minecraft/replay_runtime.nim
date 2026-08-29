## Fully prepared deterministic replay state shared by the native and WASM
## hosts. Forked from `src/ctf/replay_runtime.nim`.

import std/json

import sim, broadcast, global, replays

type
  InitializedReplay* = object
    config*: GameConfig
    sim*: SimServer
    player*: ReplayPlayer
    tracker*: BroadcastTracker

proc initReplayRuntime*(data: ReplayData, mismatchQuit: bool,
    gameEventLoggingEnabled = true): InitializedReplay =
  ## Constructs and starts replay playback from the RECORDED game config, so
  ## the viewer regenerates all four levels, every ore and every lava pocket
  ## from bytes it already has, with no fetch.
  result.config = defaultGameConfig()
  result.config.update(data.configJson)
  result.sim = initSimServer(result.config)
  result.sim.gameEventLoggingEnabled = gameEventLoggingEnabled
  result.player = initReplayPlayer(data)
  result.player.mismatchQuit = mismatchQuit
  result.player.scanReplay(result.config)
  result.player.seekReplay(result.sim, result.player.replayStartTick())
  result.player.playing = true
  result.tracker = initBroadcastTracker()
  result.tracker.resync(result.sim)

proc buildReplayViewerPacket*(sim: var SimServer, replay: ReplayPlayer,
    state: GlobalViewerState, nextState: var GlobalViewerState,
    events: JsonNode): seq[uint8] =
  ## The shared replay board and chrome packet for one viewer.
  result = sim.buildBoardPacket(state, nextState)
  ## The lead chrome (the milestone timeline, the beat markers, the lull
  ## spans) ships ONCE per viewer, keyed on presence rather than frame number.
  let sendLead = not state.leadSent and replay.scanComplete
  if sendLead:
    nextState.leadSent = true
  result.addChromeSprite(sim.buildStateJson(
    events,
    replay.playing,
    replay.replaySpeed(),
    replay.replayMaxTick(),
    replay.looping,
    true,
    replay.hashMismatchTick,
    (if sendLead: replay.leadSeries else: @[]),
    replay.replayStartTick(),
    replay.endHoldSecondsLeft(),
    replay.skipLulls,
    replay.skipLulls and replay.playing and
      replay.isLullTick(sim.tickCount),
    (if sendLead: replay.lullSpans else: @[]),
    (if sendLead: replay.beatEvents else: nil)
  ))
