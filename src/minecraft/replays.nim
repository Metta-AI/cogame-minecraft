## The binary `COWLDMCR` replay: the codec, the player, the seek, and the
## whole-episode pre-scan.
##
## Forked from `src/ctf/replays.nim`, with ONE deliberate simplification the
## design note's world size makes safe: this sim is four 32x32 integer grids
## and 960 ticks, so a SEEK RE-SIMULATES FROM TICK 0 rather than restoring a
## flatty keyframe. The starter needs keyframes because a paintbot sim carries
## ~40 MB of static map bakes; here a whole episode is microseconds of integer
## work, and dropping the keyframe machinery removes the class of bug that
## machinery exists to manage.
##
## The recorded inputs ARE the game's whole input log: one primitive per tick,
## written by the server before it steps and replayed by the same `sim.step`.
## Chat records carry the register / directive / fallback / budget_guard /
## stop / result vocabulary, plus the three CONTROL records (`start`,
## `turnend`, `stop`) that are applied by the SAME proc on record and on
## playback - a wall-clock fact cannot be re-derived from sim state, so it is
## written rather than inferred.

import std/json

import bitworld/replays as replayCodec

import sim, broadcast

export replayCodec

const
  MinecraftReplayMagic* = "COWLDMCR"
  MinecraftReplayFormatVersion* = 1'u16
  MinecraftReplaySpec* = ReplaySpec(
    magic: MinecraftReplayMagic,
    formatVersion: MinecraftReplayFormatVersion,
    gameName: GameName,
    gameVersion: GameVersion,
    joinKind: rjkNameSlotToken,
    allowChat: true,
    allowCompressed: true,
    hashOrder: rhoStop
  )
  ReplayEndHoldSeconds* = 10
  LullLeadTicks* = 40
    ## A lull is 40 consecutive ticks with no beat-worthy event and no change
    ## in the cog's cell.
  MinLullTicks* = 60
  LullSpeedBoost* = 8

type
  ReplayPlayer* = object
    data*: ReplayData
    inputIndex*: int
    chatIndex*: int
    hashIndex*: int
    playing*: bool
    looping*: bool
    speedIndex*: int
    skipLulls*: bool
    mismatchQuit*: bool
    hashValidationFailed*: bool
    hashMismatchTick*: int
    startTick*: int
    endHoldFrames*: int
    scanComplete*: bool
    leadSeries*: seq[seq[int]]
    lullSpans*: seq[array[2, int]]
    beatEvents*: JsonNode
    maxTick*: int

proc tickTime*(tick: int): uint32 =
  replayCodec.tickTime(tick, ReplayFps)

proc tickOfTime*(time: uint32): int =
  ## The inverse of `tickTime`. The pinned bitworld predates its own
  ## `timeTick`, so the conversion lives here rather than being imported.
  int((int64(time) * int64(ReplayFps) + 500'i64) div 1000'i64)

proc openReplayWriter*(path: string, configJson: string): ReplayWriter =
  replayCodec.openReplayWriter(path, configJson, MinecraftReplaySpec)

proc parseReplayBytes*(bytes: string): ReplayData =
  replayCodec.parseReplayBytes(bytes, MinecraftReplaySpec)

proc loadReplay*(path: string): ReplayData =
  replayCodec.loadReplay(path, MinecraftReplaySpec)

proc writePrimitive*(writer: var ReplayWriter, tick: int,
    primitive: Primitive) =
  ## The action stream. Lives here rather than in server.nim because the input
  ## log IS the replay: the test that proves the recorded primitives
  ## re-simulate to the identical hash chain has to write it exactly the way
  ## the server does, and two copies of this would be two chances to drift.
  writer.writeInput(ReplayInput(time: tickTime(tick), player: 0'u8,
    keys: uint8(ord(primitive))))

proc startRecord*(): string =
  $(%*{"k": "start"})

proc turnEndRecord*(): string =
  $(%*{"k": "turnend"})

proc isControlRecord*(message: string): bool =
  message.len > 0 and message[0] == '{'

proc applyControlRecord*(sim: var SimServer, message: string) =
  ## The ONE proc that applies a control record, on record and on playback
  ## alike. Anything it does not recognise is chrome, not physics.
  if not isControlRecord(message):
    return
  var node: JsonNode
  try:
    node = parseJson(message)
  except CatchableError:
    return
  if node.kind != JObject or not node.hasKey("k"):
    return
  case node["k"].getStr()
  of "start":
    if sim.phase == Lobby:
      sim.startGame()
  of "turnend":
    sim.noteTurnEnd()
  of "stop":
    let rule = node{"endRule"}.getStr(EndRuleWallClock)
    let reason =
      if rule == EndRuleFault: ReasonFault
      elif rule == EndRuleWallClock: ReasonDeadline
      else: ReasonComplete
    sim.finishEpisode(rule, reason)
  else:
    discard

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  result.data = data
  result.playing = true
  result.looping = true
  result.speedIndex = 0
  result.skipLulls = true
  result.hashMismatchTick = -1
  result.startTick = 0
  result.beatEvents = newJArray()
  result.maxTick = 0
  for hash in data.hashes:
    result.maxTick = max(result.maxTick, int(hash.tick))
  if result.maxTick == 0:
    result.maxTick = data.inputs.len

proc replaySpeed*(replay: ReplayPlayer): int =
  PlaybackSpeeds[clamp(replay.speedIndex, 0, PlaybackSpeeds.high)]

proc replayMaxTick*(replay: ReplayPlayer): int =
  max(1, replay.maxTick)

proc replayStartTick*(replay: ReplayPlayer): int =
  max(0, replay.startTick)

proc endHoldSecondsLeft*(replay: ReplayPlayer): int =
  (replay.endHoldFrames + TargetFps - 1) div TargetFps

proc cancelEndHold*(replay: var ReplayPlayer) =
  replay.endHoldFrames = 0

proc isLullTick*(replay: ReplayPlayer, tick: int): bool =
  for span in replay.lullSpans:
    if tick >= span[0] and tick <= span[1]:
      return true
  false

proc checkReplayHash(replay: var ReplayPlayer, sim: SimServer) =
  ## One divergent bit is caught at the tick it happens and surfaced as
  ## `mismatchTick` in `#mmwarn`.
  while replay.hashIndex < replay.data.hashes.len and
      int(replay.data.hashes[replay.hashIndex].tick) < sim.tickCount:
    inc replay.hashIndex
  if replay.hashIndex >= replay.data.hashes.len:
    return
  if int(replay.data.hashes[replay.hashIndex].tick) != sim.tickCount:
    return
  if replay.data.hashes[replay.hashIndex].hash != sim.gameHash():
    if not replay.hashValidationFailed:
      replay.hashValidationFailed = true
      replay.hashMismatchTick = sim.tickCount
  inc replay.hashIndex

proc stepReplay*(replay: var ReplayPlayer, sim: var SimServer) =
  ## One recorded tick: apply this tick's control records, run the recorded
  ## primitive through the SAME `sim.step`, then re-check the hash.
  let now = tickTime(sim.tickCount)
  while replay.chatIndex < replay.data.chats.len and
      replay.data.chats[replay.chatIndex].time <= now:
    sim.applyControlRecord(replay.data.chats[replay.chatIndex].message)
    inc replay.chatIndex
  var primitive = pNoop
  if replay.inputIndex < replay.data.inputs.len:
    let raw = int(replay.data.inputs[replay.inputIndex].keys)
    if raw >= ord(low(Primitive)) and raw <= ord(high(Primitive)):
      primitive = Primitive(raw)
    inc replay.inputIndex
  sim.step(primitive)
  replay.checkReplayHash(sim)

proc drainControlRecords*(replay: var ReplayPlayer, sim: var SimServer) =
  ## Applies every control record still ahead of the playhead.
  ##
  ## The last records an episode writes - the wall-clock or fault `stop`, the
  ## final `turnend`, the `result` - carry the time of the tick AFTER the last
  ## recorded primitive, so a playback that stops when the inputs run out
  ## would never apply them and would re-derive `turnCap` for an episode that
  ## really ended on the wall clock. The stop is a LOAD-BEARING record: it is
  ## applied by the same proc on record and on playback, and this is where the
  ## trailing ones land.
  while replay.chatIndex < replay.data.chats.len:
    sim.applyControlRecord(replay.data.chats[replay.chatIndex].message)
    inc replay.chatIndex

proc resetPlayback(replay: var ReplayPlayer, sim: var SimServer) =
  sim = initSimServer(sim.config)
  replay.inputIndex = 0
  replay.chatIndex = 0
  replay.hashIndex = 0

proc seekReplay*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  ## A seek RE-SIMULATES from tick 0. Four 32x32 integer grids over at most
  ## 960 ticks is microseconds, so there is no keyframe to restore and no
  ## keyframe to get wrong.
  let target = clamp(tick, 0, replay.replayMaxTick())
  replay.resetPlayback(sim)
  while sim.tickCount < target and
      replay.inputIndex < replay.data.inputs.len:
    replay.stepReplay(sim)
  if replay.inputIndex >= replay.data.inputs.len:
    replay.drainControlRecords(sim)

proc applyReplaySeek*(replay: var ReplayPlayer, sim: var SimServer,
    tick: int) =
  replay.seekReplay(sim, tick)
  replay.cancelEndHold()

proc applyReplayCommand*(replay: var ReplayPlayer, sim: var SimServer,
    command: char) =
  ## The transport, exactly as the starter's chrome sends it.
  case command
  of '.', ' ':
    replay.playing = not replay.playing
  of 'b':
    replay.seekReplay(sim, max(0, sim.tickCount - 1))
  of 'r':
    replay.seekReplay(sim, replay.replayStartTick())
  of 'e':
    replay.seekReplay(sim, replay.replayMaxTick())
  of '>':
    replay.seekReplay(sim, min(replay.replayMaxTick(),
      sim.tickCount + 5 * TargetFps))
  of 'l':
    replay.looping = not replay.looping
  of 'f':
    replay.skipLulls = not replay.skipLulls
  of '1' .. '9':
    let index = ord(command) - ord('1')
    if index <= PlaybackSpeeds.high:
      replay.speedIndex = index
  else:
    discard

proc scanReplay*(replay: var ReplayPlayer, config: GameConfig) =
  ## The load-time pre-scan: re-simulate the whole episode once, headlessly,
  ## and record the per-tick cumulative `milestoneScore`, the tick each rung
  ## lit, the beat ticks and the lull spans. That is what lets the milestone
  ## timeline, the strata gauge and the scrubber beats draw at FULL WIDTH on
  ## the first frame instead of growing in.
  var
    sim = initSimServer(config)
    walker = initReplayPlayer(replay.data)
    tracker = initBroadcastTracker()
    lastScore = -1
    lastEventTick = 0
    lastCell = (-1, -1, -1)
    spans: seq[array[2, int]] = @[]
    quietStart = -1
  replay.leadSeries = @[]
  replay.beatEvents = newJArray()
  tracker.resync(sim)
  var started = false
  while walker.inputIndex < walker.data.inputs.len:
    walker.stepReplay(sim)
    if not started and sim.phase == Playing:
      started = true
      replay.startTick = sim.tickCount
    let events = newJArray()
    sim.stepEvents(tracker, events)
    let score = sim.ledger.milestoneScore()
    if score != lastScore:
      lastScore = score
      replay.leadSeries.add(@[sim.tickCount, score])
    var beatHere = false
    for event in events:
      let kind = event{"k"}.getStr()
      case kind
      of "milestone":
        replay.beatEvents.add(%*{"k": "milestone", "t": sim.tickCount,
          "id": event{"id"}.getStr(), "n": event{"n"}.getInt(),
          "of": event{"of"}.getInt()})
        beatHere = true
      of "descend":
        if event{"first"}.getBool():
          replay.beatEvents.add(%*{"k": "newdepth", "t": sim.tickCount,
            "to": event{"to"}.getStr()})
        beatHere = true
      of "death":
        replay.beatEvents.add(%*{"k": "death", "t": sim.tickCount})
        beatHere = true
      of "end":
        replay.beatEvents.add(%*{"k": "end", "t": sim.tickCount,
          "endRule": event{"endRule"}.getStr(),
          "milestones": event{"milestones"}.getInt(),
          "score": event{"score"}.getInt()})
        beatHere = true
      of "mine", "craft", "smelt", "place", "lava", "bridge", "ascend":
        beatHere = true
      else:
        discard
    let cell = (sim.cog.x, sim.cog.y, sim.cog.z)
    if beatHere or cell != lastCell:
      lastCell = cell
      lastEventTick = sim.tickCount
      if quietStart >= 0:
        if sim.tickCount - quietStart >= MinLullTicks:
          spans.add([quietStart, sim.tickCount - 1])
        quietStart = -1
    elif quietStart < 0 and sim.tickCount - lastEventTick >= LullLeadTicks:
      quietStart = sim.tickCount
  if quietStart >= 0 and sim.tickCount - quietStart >= MinLullTicks:
    spans.add([quietStart, sim.tickCount])
  replay.lullSpans = spans
  replay.maxTick = max(replay.maxTick, sim.tickCount)
  ## The fallback beats come from the chat stream, not from state deltas: a
  ## fallback is a fact about the DECISION layer, which the sim never sees.
  for chat in replay.data.chats:
    if not isControlRecord(chat.message):
      continue
    try:
      let node = parseJson(chat.message)
      if node.kind == JObject and node{"k"}.getStr() == "fallback" and
          node{"attempt"}.getInt() == 2:
        replay.beatEvents.add(%*{
          "k": "fallback", "t": tickOfTime(chat.time),
          "cause": node{"cause"}.getStr()})
    except CatchableError:
      discard
  replay.scanComplete = true

proc advanceReplayFrame*(replay: var ReplayPlayer, sim: var SimServer,
    tracker: var BroadcastTracker, seekTicks: openArray[int],
    commands: openArray[char]): JsonNode =
  ## Applies viewer controls and advances ONE public presentation frame.
  ##
  ## Playback rate: one tick per three animation frames at 30 fps = 10
  ## ticks/second, so a 960-tick episode plays for 96 s and even a 400-tick
  ## episode plays for 40 s - which is what lets `viewer_smoke.mjs --soak 10`
  ## observe real advancement instead of a legitimately-finished replay.
  var didSeek = false
  for tick in seekTicks:
    replay.applyReplaySeek(sim, tick)
    didSeek = true
  for command in commands:
    let before = sim.tickCount
    replay.applyReplayCommand(sim, command)
    if sim.tickCount != before:
      didSeek = true
  if didSeek:
    tracker.resync(sim)
    replay.cancelEndHold()

  result = newJArray()
  if not replay.playing:
    return
  if replay.inputIndex >= replay.data.inputs.len:
    replay.drainControlRecords(sim)
    if replay.looping:
      if replay.endHoldFrames > 0:
        dec replay.endHoldFrames
      else:
        replay.seekReplay(sim, replay.replayStartTick())
        tracker.resync(sim)
    return
  var steps = replay.replaySpeed()
  if replay.skipLulls and replay.isLullTick(sim.tickCount):
    steps = steps * LullSpeedBoost
  for _ in 0 ..< steps:
    if replay.inputIndex >= replay.data.inputs.len:
      replay.drainControlRecords(sim)
      if replay.endHoldFrames == 0:
        replay.endHoldFrames = ReplayEndHoldSeconds * TargetFps
      break
    replay.stepReplay(sim)
    sim.stepEvents(tracker, result)
