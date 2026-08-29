## The mummy HTTP/websocket server implementing the Coworld contract.
##
## Forked from `src/ctf/server.nim`, keeping every load-bearing piece and
## dropping the paintbot surfaces the design note deletes (the reward socket,
## the admin/kick control plane, debug sprites, the map editor and the
## multi-game campaign). What is KEPT, and why:
##
##  - `/healthz`, `/player?slot&token`, `/global`, `/replay`, `/client/*`, the
##    join/auth path and the artifact-write block;
##  - the `Ping -> Pong` branch in `websocketHandler`, VERBATIM (lux-ai 0.1.0
##    and snake-royale 0.1.0 both lost it), and NO `kind != TextMessage`
##    guard, which would drop the seat's binary registration frames;
##  - the player websocket CLOSES unless the token matches the seat (the
##    certifier probes with a bad token - cogame-flatland 0.1.1);
##  - `declarePlayerFailure`'s CLOSED payload - exactly
##    `{"message", "failed_policy_index"}`, nothing else;
##  - the `wallClockBudgetSeconds` stop at the top of every loop iteration,
##    written as the load-bearing `stop` record;
##  - the `gameOverTicks` grace, so `/healthz` and `/global` keep answering
##    for a bounded window after the artifacts are written (the lantern 0.1.3
##    scar);
##  - the registration interception: the seat's Sprite v1 chat message is
##    consumed as REGISTRATION, never applied as speech and never written to
##    the replay chat stream; the server writes a redacted `register` record
##    instead.

import std/[json, locks, monotimes, os, strutils, tables, times]

import bitworld/client as bitworldClient
import bitworld/runtime
import bitworld/spriteprotocol
import mummy

import sim, global, broadcast, replays, replay_runtime, events, wire_constants,
  directives, driver, baselines, decide

type
  WebSocketAppState = object
    lock: Lock
    replayLoaded: bool
    chatMessages: Table[WebSocket, string]
    playerIndices: Table[WebSocket, int]
    playerAddresses: Table[WebSocket, string]
    playerSlots: Table[WebSocket, int]
    playerTokens: Table[WebSocket, string]
    playerReady: Table[WebSocket, bool]
    globalViewers: Table[WebSocket, GlobalViewerState]
    playerSockets: Table[WebSocket, bool]
    closedSockets: seq[WebSocket]
    config: GameConfig

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

const
  HealthPath = "/healthz"
  ReplayDataPath = "/replay-data"
  ArtRoutePrefix = "/client/art/"
  BroadcastFontPath = "/client/font.ttf"
  CogAvatarPath = "/client/cog_avatar.png"
  MaxWsFrameBytes* = 900_000
  ShutdownGraceSeconds = 20

  EmbeddedBroadcastReplayHtml = staticRead(
      "../../client/replay_broadcast.html").replace(
    "<!-- CHROME_COMMON -->",
    "<script>" & staticRead("../../client/chrome_common.js") & "</script>"
  ).replace(
    "<!-- BROADCAST_CORE -->",
    "<script>" & staticRead("../../client/broadcast_core.js") & "</script>"
  ).spliceWireConstants()

  WallTextureHorizontal = staticRead("../../client/art/walls/wall_h.jpg")
  WallTextureVertical = staticRead("../../client/art/walls/wall_v.jpg")
  BroadcastFont = staticRead("../../data/font.ttf")
  CogAvatarArt = staticRead("../../data/art/cog_avatar.png")
  LockerRoomAssets = [
    ("/client/art/lockerroom/bg.jpg",
      staticRead("../../client/art/lockerroom/bg.jpg")),
    ("/client/art/lockerroom/red_1.webp",
      staticRead("../../client/art/lockerroom/red_1.webp")),
    ("/client/art/lockerroom/red_2.webp",
      staticRead("../../client/art/lockerroom/red_2.webp")),
    ("/client/art/lockerroom/red_3.webp",
      staticRead("../../client/art/lockerroom/red_3.webp")),
    ("/client/art/lockerroom/red_5.webp",
      staticRead("../../client/art/lockerroom/red_5.webp")),
    ("/client/art/lockerroom/red_6.webp",
      staticRead("../../client/art/lockerroom/red_6.webp")),
    ("/client/art/walls/wall_h.jpg", WallTextureHorizontal),
    ("/client/art/walls/wall_v.jpg", WallTextureVertical)
  ]

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.replayLoaded = false
  appState.chatMessages = initTable[WebSocket, string]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerAddresses = initTable[WebSocket, string]()
  appState.playerSlots = initTable[WebSocket, int]()
  appState.playerTokens = initTable[WebSocket, string]()
  appState.playerReady = initTable[WebSocket, bool]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.playerSockets = initTable[WebSocket, bool]()
  appState.closedSockets = @[]
  appState.config = defaultGameConfig()

proc markSocketClosed(websocket: WebSocket): bool =
  result = websocket notin appState.closedSockets
  if result:
    appState.closedSockets.add(websocket)

proc isWebSocketUpgrade(request: Request): bool =
  request.headers["Sec-WebSocket-Key"].len > 0

proc playerSlotOf(request: Request): int =
  let text = request.queryParams.getOrDefault("slot", "").strip()
  if text.len == 0:
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return MaxPlayers
  if result < 0 or result >= MaxPlayers:
    return MaxPlayers

proc playerTokenOf(request: Request): string =
  request.queryParams.getOrDefault("token", "").strip()

proc cleanPlayerName(name: string): string =
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc playerIdentity(request: Request, slot: int, token: string): string =
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.configuredPlayerName(slot, token)
  if result.len == 0:
    result = "Player" & $(max(0, slot) + 1)

proc tokenAccepted(config: GameConfig, slot: int, token: string): bool =
  ## The player websocket CLOSES unless the token matches the seat: the
  ## certifier probes this route with a BAD token and a server that accepts it
  ## fails certification (cogame-flatland 0.1.1).
  if not config.hasConfiguredTokens():
    return true
  if token.len == 0:
    return false
  if config.hasConfiguredToken(token):
    if slot < 0:
      return true
    return config.slotForToken(token) == slot
  false

proc disconnectWebSocket(websocket: WebSocket) =
  try:
    websocket.close()
  except CatchableError:
    discard

proc respondForbidden(request: Request, body: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  request.respond(403, headers, body)

proc removePlayerSocketState(websocket: WebSocket): int =
  result = -1
  if websocket in appState.playerIndices:
    result = appState.playerIndices[websocket]
    appState.playerIndices.del(websocket)
  appState.chatMessages.del(websocket)
  appState.playerAddresses.del(websocket)
  appState.playerSlots.del(websocket)
  appState.playerTokens.del(websocket)
  appState.playerReady.del(websocket)
  appState.playerSockets.del(websocket)

proc declarePlayerFailure(slot: int, message: string) =
  ## The platform's CLOSED payload - exactly `{"message",
  ## "failed_policy_index"}`, nothing else. Best-effort: outside the platform
  ## (env unset) this is a no-op, and a declaration write failure must never
  ## mask what follows.
  try:
    writeCogameEnv(
      "COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json"
    )
  except CatchableError as error:
    echo "player-failure declaration failed: ", error.msg

proc parseRegistration(text: string): tuple[ok: bool, prompt, scripted,
    policy: string] =
  ## The seat's ONE Sprite v1 chat message, read as its registration:
  ##   {"type":"register","prompt":"...","scripted":"miner"|null,"policy":"..."}
  ## Anything that is not that object is not a registration.
  result = (false, "", "", "")
  if text.len == 0 or text[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject or node{"type"}.getStr() != "register":
    return
  result.ok = true
  result.prompt = node{"prompt"}.getStr()
  if not node{"scripted"}.isNil and node{"scripted"}.kind == JString:
    result.scripted = node{"scripted"}.getStr()
  result.policy = node{"policy"}.getStr()

# ---------------------------------------------------------------------------
#  HTTP
# ---------------------------------------------------------------------------

proc httpHandler(request: Request) =
  if request.path == HealthPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, "healthy")
  elif request.path == WebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let
      slot = request.playerSlotOf()
      token = request.playerTokenOf()
      identity = request.playerIdentity(slot, token)
    var accepted = false
    {.gcsafe.}:
      withLock appState.lock:
        accepted = appState.config.tokenAccepted(slot, token)
    if not accepted:
      request.respondForbidden("player token does not match the seat\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        discard removePlayerSocketState(websocket)
        appState.globalViewers.del(websocket)
        appState.playerSockets[websocket] = true
        appState.playerAddresses[websocket] = identity
        appState.playerSlots[websocket] = slot
        appState.playerTokens[websocket] = token
        appState.playerIndices[websocket] =
          if appState.replayLoaded: -1 else: 0x7fffffff
        appState.playerReady[websocket] = false
    echo "player connected: ", identity
  elif (request.path == GlobalWebSocketPath or
        request.path == ReplayWebSocketPath) and
      request.httpMethod == "GET" and request.isWebSocketUpgrade():
    if request.queryParams.getOrDefault("token", "").len > 0:
      ## A viewer must never present player credentials.
      request.respondForbidden("viewer sockets take no player credentials\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        discard removePlayerSocketState(websocket)
        appState.globalViewers[websocket] = initGlobalViewerState()
  elif request.path == BroadcastFontPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "font/ttf"
    headers["Cache-Control"] = "public, max-age=3600"
    request.respond(200, headers, BroadcastFont)
  elif request.path == CogAvatarPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "image/png"
    headers["Cache-Control"] = "public, max-age=3600"
    request.respond(200, headers, CogAvatarArt)
  elif request.httpMethod == "GET" and request.path.startsWith(ArtRoutePrefix):
    var served = false
    for (path, art) in LockerRoomAssets:
      if request.path == path:
        var headers: HttpHeaders
        headers["Content-Type"] =
          if path.endsWith(".webp"): "image/webp"
          elif path.endsWith(".png"): "image/png"
          else: "image/jpeg"
        headers["Cache-Control"] = "public, max-age=3600"
        request.respond(200, headers, art)
        served = true
        break
    if not served:
      var headers: HttpHeaders
      headers["Content-Type"] = "text/plain"
      request.respond(404, headers, "not found")
  elif request.path in [bitworldClient.ReplayClientRoute,
      bitworldClient.CoworldReplayClientRoute] and
      request.httpMethod == "GET":
    ## The DEVELOPER replay route. It is never declared to the platform: the
    ## hosted replay is the static wasm bundle and nothing else.
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, EmbeddedBroadcastReplayHtml)
  elif request.path == ReplayDataPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "application/octet-stream"
    request.respond(404, headers, "")
  elif bitworldClient.serveClientRoute(request,
      bitworldClient.GlobalClientRoute):
    discard
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "minecraft server")

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
    message: Message) =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    ## The `Ping -> Pong` branch, verbatim. There is deliberately NO
    ## `kind != TextMessage` guard here: the seat's registration arrives as a
    ## BINARY Sprite v1 frame and a guard would drop it.
    if message.kind == Ping:
      websocket.send(message.data, Pong)
    else:
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.globalViewers:
            appState.globalViewers[websocket].applyGlobalViewerMessage(
              message.data)
          elif websocket in appState.playerSockets:
            if message.data.len == 1 and
                message.data[0].uint8 == SpriteClientReady:
              appState.playerReady[websocket] = true
            else:
              var text = ""
              for item in message.data.parseSpriteClientMessages():
                if item.kind == SpriteClientChatMessage:
                  text.add(item.text)
                elif item.kind == SpriteClientReadyMessage:
                  appState.playerReady[websocket] = true
              if text.len > 0:
                appState.chatMessages[websocket] = text
  of ErrorEvent, CloseEvent:
    var who = ""
    {.gcsafe.}:
      withLock appState.lock:
        if markSocketClosed(websocket) and
            websocket in appState.playerAddresses:
          who = appState.playerAddresses[websocket]
    if who.len > 0:
      echo "player disconnected: ", who

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc runFrameLimiter(previousTick: var MonoTime, fastMode: bool) =
  ## The lobby always paces at wall clock: fast-forwarding there spins the
  ## loop hot and starves mummy's upgrade path so the seat never finishes
  ## connecting (certifier deadlock at "waiting for players").
  if fastMode:
    previousTick = getMonoTime()
    return
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  while true:
    let elapsed = getMonoTime() - previousTick
    if elapsed >= frameDuration:
      break
    sleep(max(1, min(2, int((frameDuration - elapsed).inMilliseconds))))
  previousTick = getMonoTime()

# ---------------------------------------------------------------------------
#  The loop
# ---------------------------------------------------------------------------

proc runServerLoop*(host = "0.0.0.0", port = 8080,
    initialConfig = defaultGameConfig(), saveReplayPath = "",
    loadReplayPath = "", saveScoresPath = "",
    runtimeConfig = RuntimeConfig()) =
  initAppState()
  if saveReplayPath.len > 0 and loadReplayPath.len > 0:
    raise newException(MinecraftError,
      "Cannot save and load a replay together")

  var replayLoaded = loadReplayPath.len > 0
  var replayData =
    if replayLoaded:
      try:
        loadReplay(loadReplayPath)
      except CatchableError as error:
        echo "replay load failed (serving without replay): ", error.msg
        replayLoaded = false
        ReplayData()
    else:
      ReplayData()
  var initialized =
    if replayLoaded: initReplayRuntime(replayData, runtimeConfig.mismatchQuit)
    else: InitializedReplay()
  var config = if replayLoaded: initialized.config else: initialConfig
  var
    replayWriter = openReplayWriter(saveReplayPath, config.configJson())
    replayPlayer =
      if replayLoaded: move(initialized.player) else: ReplayPlayer()
  defer:
    replayWriter.closeReplayWriter()
  appState.replayLoaded = replayLoaded
  appState.config = config

  let eventsPath = block:
    let uri = getEnv("COGAME_EVENTS_URI")
    if uri.len == 0: ""
    elif uri.startsWith("file://"): uri[7 .. ^1]
    else:
      raise newException(ValueError,
        "COGAME_EVENTS_URI must be a file:// path, got: " & uri)

  var
    sim = if replayLoaded: move(initialized.sim) else: initSimServer(config)
    tracker =
      if replayLoaded: move(initialized.tracker) else: initBroadcastTracker()
    collectedEvents: seq[SimEvent] = @[]
  sim.collectEvents = eventsPath.len > 0
  tracker.resync(sim)

  block:
    ## Bake the board tile bed BEFORE the listener opens: a viewer's
    ## first-message clock starts at its successful connect, so nothing may be
    ## accepted until every frame the loop will ever build can be assembled
    ## instantly.
    let warmStart = getMonoTime()
    sim.warmBoardRenderCaches()
    echo "board tiles baked in ",
      (getMonoTime() - warmStart).inMilliseconds, " ms"

  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 4)
  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()
  echo "minecraft listening on ", host, ":", port

  var
    engine = if replayLoaded: DecisionEngine() else: initDecisionEngine(sim)
    lastTick = getMonoTime()
    episodeStart = getMonoTime()
    quitAfterFrame = false
    turnActive = false
    turnTicksUsed = 0
    turnIndex = 0
    queue: seq[Primitive] = @[]
    lastPlanView: JsonNode = nil
    registrationSeen = false
    noShowDeclared = false
    graceTicks = 0

  while true:
    var
      globalViewers: seq[WebSocket] = @[]
      globalStates: seq[GlobalViewerState] = @[]
      playerSockets: seq[WebSocket] = @[]
      replayCommands: seq[char] = @[]
      replaySeekTicks: seq[int] = @[]

    # --- the engine's own hard stop, checked before anything else ----------
    if not replayLoaded and sim.phase != GameOver and
        (getMonoTime() - episodeStart).inSeconds.int >=
          config.wallClockBudgetSeconds:
      echo "wall-clock budget of ", config.wallClockBudgetSeconds,
        "s reached; settling the episode at this tick"
      sim.stopDetail = "wall-clock budget reached"
      let record = stopRecord(sim.tickCount, EndRuleWallClock)
      replayWriter.writeChat(tickTime(sim.tickCount), 0, record)
      sim.applyControlRecord(record)
      quitAfterFrame = true

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          let index = removePlayerSocketState(websocket)
          appState.globalViewers.del(websocket)
          if index >= 0 and index < 0x7fffffff:
            sim.removePlayerAt(index)
        appState.closedSockets.setLen(0)

        if not replayLoaded:
          ## Joins are strictly slot-sequential, exactly as the starter's are.
          var pending: seq[WebSocket] = @[]
          for websocket, index in appState.playerIndices.pairs:
            if index == 0x7fffffff:
              pending.add(websocket)
          for websocket in pending:
            let
              address = appState.playerAddresses.getOrDefault(websocket,
                "unknown")
              slot = appState.playerSlots.getOrDefault(websocket, -1)
              token = appState.playerTokens.getOrDefault(websocket, "")
            if sim.phase != Lobby or not sim.canAddPlayer():
              appState.playerIndices[websocket] = -1
              continue
            try:
              let index = sim.addPlayer(address, slot, token)
              appState.playerIndices[websocket] = index
              replayWriter.writeJoin(tickTime(sim.tickCount), index, address,
                sim.players[index].joinOrder, token)
            except CatchableError as error:
              echo "join refused: ", error.msg
              appState.playerIndices[websocket] = -1

          ## Registration interception. A seat's chat IS its registration,
          ## consumed here and never applied as speech nor written to the
          ## replay chat stream: the prompt is a secret. A registration that
          ## cannot be applied YET is HELD, not dropped.
          var held: seq[(WebSocket, string)] = @[]
          for websocket, chatText in appState.chatMessages.pairs:
            let index = appState.playerIndices.getOrDefault(websocket, -1)
            let registration = parseRegistration(chatText)
            if index < 0 or index >= engine.seats.len:
              if registration.ok:
                held.add((websocket, chatText))
              continue
            if not registration.ok:
              continue
            var policy = engine.seats[index]
            let first = not policy.registered
            policy.registered = true
            policy.prompt = registration.prompt.truncateRunes(MaxPromptRunes)
            policy.isLlm = policy.prompt.len > 0
            policy.baseline = parseBaseline(registration.scripted)
            policy.label =
              if registration.policy.len > 0: registration.policy
              elif policy.isLlm: "prompt"
              else: $policy.baseline
            engine.seats[index] = policy
            if index < sim.seatPolicyKind.len:
              sim.seatPolicyKind[index] = engine.policyKind(index)
            if first:
              registrationSeen = true
              replayWriter.writeChat(tickTime(sim.tickCount), index,
                registerRecord(index, seatAlias(index), policy.label,
                  engine.policyKind(index), $policy.baseline))
              echo "seat ", index, " registered: kind=",
                engine.policyKind(index), " baseline=", $policy.baseline
          appState.chatMessages.clear()
          for (websocket, chatText) in held:
            appState.chatMessages[websocket] = chatText

        for websocket in appState.playerSockets.keys:
          playerSockets.add(websocket)
        for websocket, state in appState.globalViewers.pairs:
          globalViewers.add(websocket)
          globalStates.add(state)
          if state.replaySeekTick >= 0:
            replaySeekTicks.add(state.replaySeekTick)
          for command in state.replayCommands:
            replayCommands.add(command)
          appState.globalViewers[websocket].replayCommands.setLen(0)
          appState.globalViewers[websocket].replaySeekTick = -1

    # --- lobby --------------------------------------------------------------
    if not replayLoaded and sim.phase == Lobby:
      inc sim.lobbyTicks
      let seated = sim.players.len >= config.numAgents
      if seated and registrationSeen:
        let record = startRecord()
        replayWriter.writeChat(tickTime(sim.tickCount), 0, record)
        sim.applyControlRecord(record)
        echo "run starting: seed ", config.seed, " variant ",
          config.variantText()
      elif sim.lobbyTicks >= config.lobbyJoinTimeoutTicks:
        ## A seat that never connected, or connected and never registered,
        ## does NOT end the episode: the no-show is reported to the platform
        ## and the run plays out on the published `miner` baseline. LOUD,
        ## never a silent default (the grf-football 2026-08-27 scar).
        if not noShowDeclared:
          noShowDeclared = true
          let why =
            if not seated: "never joined the lobby"
            else: "joined but sent no register record"
          echo "ERROR: seat 0 ", why, " within ",
            config.lobbyJoinTimeoutTicks, " lobby ticks; the run plays the ",
            "published miner baseline and the failure is declared"
          declarePlayerFailure(0, "player slot 0 " & why & " within " &
            $config.lobbyJoinTimeoutTicks & " lobby ticks (~" &
            $(config.lobbyJoinTimeoutTicks div TargetFps) &
            "s); its cog plays the miner baseline")
          sim.deadSeats[0] = true
        let record = startRecord()
        replayWriter.writeChat(tickTime(sim.tickCount), 0, record)
        sim.applyControlRecord(record)

    # --- the decision turn, then the tick ----------------------------------
    var frameEventsJson = newJArray()
    if replayLoaded:
      frameEventsJson = replayPlayer.advanceReplayFrame(sim, tracker,
        replaySeekTicks, replayCommands)
    elif sim.phase == Playing:
      if not turnActive:
        turnActive = true
        turnTicksUsed = 0
        let prevBlocked = sim.lastPlan.blocked
        sim.lastPlan = LastPlan(interrupted: "",
          notes: sim.lastPlan.notes)
        lastPlanView = sim.observationJson(turnIndex, includeNotes = false)
        let elapsedSeconds = (getMonoTime() - episodeStart).inSeconds.int
        for record in engine.turn(sim, turnIndex, elapsedSeconds):
          replayWriter.writeChat(tickTime(sim.tickCount), 0, record)
        var plan = engine.plans[0]
        let expanded = expandPlan(sim, plan)
        queue = expanded.queue
        sim.lastPlan.truncated = expanded.truncated or plan.truncatedActions
        sim.lastPlan.dropped = plan.dropped
        sim.lastPlan.unreachable = expanded.unreachable
        sim.actionsDropped += plan.dropped
        sim.repliesRepaired += plan.dropped
        sim.macrosUnreachable += expanded.unreachable
        if plan.notes.len > 0:
          sim.lastPlan.notes = plan.notes
        let record = directiveRecord(turnIndex, sim.gameTicksElapsed(), 0,
          seatAlias(0), plan, primitiveNames(queue), sim.lastPlan.truncated,
          sim.lastPlan.dropped, sim.lastPlan.unreachable, prevBlocked, "",
          lastPlanView)
        replayWriter.writeChat(tickTime(sim.tickCount), 0, record)
        ## The SAME proc a playback uses: the feed line and the per-seat
        ## llm/fallback counts are derived from the record that was just
        ## written, never from state the replay does not carry.
        sim.applyControlRecord(record)
        sim.emitEvent(Directive, what = $plan.source, amount = turnIndex,
          content = plan.say)

      var primitive = pNoop
      if queue.len > 0:
        primitive = queue[0]
        queue.delete(0)
      sim.lastPlan.executed.add($primitive)
      replayWriter.writePrimitive(sim.tickCount, primitive)
      try:
        sim.step(primitive)
      except CatchableError as error:
        echo "minecraft: HOST ERROR at tick ", sim.tickCount, ": ", error.msg
        sim.stopDetail = error.msg
        let record = stopRecord(sim.tickCount, EndRuleFault)
        replayWriter.writeChat(tickTime(sim.tickCount), 0, record)
        sim.applyControlRecord(record)
        quitAfterFrame = true
      replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())
      inc turnTicksUsed
      if sim.collectEvents:
        for event in sim.events:
          collectedEvents.add(event)
        sim.events.setLen(0)
      if sim.interruptRequested or turnTicksUsed >= config.turnTicks or
          sim.phase == GameOver:
        turnActive = false
        inc turnIndex
        queue.setLen(0)
        ## The turn-end record is written even on the tick that ended the
        ## episode: `turnsPlayed` is part of the results document and has to
        ## count the turn that was actually played.
        let record = turnEndRecord()
        replayWriter.writeChat(tickTime(sim.tickCount), 0, record)
        sim.applyControlRecord(record)
      if sim.phase == GameOver:
        quitAfterFrame = true
    else:
      ## Lobby or GameOver: the clock still runs, so a lobby tick advances.
      if not replayLoaded and sim.phase == GameOver:
        inc graceTicks

    # --- frames -------------------------------------------------------------
    ## ONE binary message per tick to each seat. The seat sends no inputs and
    ## must never see the board - it is partially observed, and shipping it
    ## the level would leak every cell it has not looked at - so the frame is
    ## EMPTY. It is still sent, because one message per tick is the frame
    ## contract: the reference player counts frames to pace its registration
    ## re-sends, and a seat that receives nothing cannot tell a live game from
    ## a dead socket.
    for websocket in playerSockets:
      try:
        websocket.send("", BinaryMessage)
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(websocket)
    if not replayLoaded:
      sim.stepEvents(tracker, frameEventsJson)
    for i in 0 ..< globalViewers.len:
      var nextState: GlobalViewerState
      let packet =
        if replayLoaded:
          sim.buildReplayViewerPacket(replayPlayer, globalStates[i],
            nextState, frameEventsJson)
        else:
          sim.buildSpriteProtocolUpdates(globalStates[i], nextState,
            frameEventsJson, true, 1, max(1, config.maxTicks), false, false,
            -1)
      if packet.len == 0:
        continue
      try:
        for chunk in chunkSpritePacket(packet, MaxWsFrameBytes):
          globalViewers[i].send(blobFromBytes(chunk), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if globalViewers[i] in appState.globalViewers:
              ## The websocket thread keeps writing viewer INPUT into this
              ## entry while the frame was built from an earlier snapshot, so
              ## merge rather than clobber: a seek landing there would
              ## otherwise be silently lost.
              let pending = appState.globalViewers[globalViewers[i]]
              var merged = nextState
              merged.mouseX = pending.mouseX
              merged.mouseY = pending.mouseY
              merged.mouseDown = pending.mouseDown
              if pending.clickPending:
                merged.clickPending = true
              if pending.replaySeekTick >= 0:
                merged.replaySeekTick = pending.replaySeekTick
              if pending.replayCommands.len > 0:
                merged.replayCommands.add(pending.replayCommands)
              appState.globalViewers[globalViewers[i]] = merged
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(globalViewers[i])

    if quitAfterFrame:
      ## The `result` control record: the whole results document, written once
      ## into the replay chat stream at episode end, so the replay is
      ## SELF-SUFFICIENT.
      replayWriter.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
      replayWriter.closeReplayWriter()
      if saveReplayPath.len > 0 and fileExists(saveReplayPath):
        echo "Replay written: ", saveReplayPath, " (",
          getFileSize(saveReplayPath), " bytes)"
        runtimeConfig.writeReplay(readFile(saveReplayPath))
      if eventsPath.len > 0:
        writeFile(eventsPath, collectedEvents.eventsJsonl(sim.tickCount))
        echo "Events written: ", eventsPath, " (", collectedEvents.len,
          " events)"
      let resultsJson = sim.runResultsJson() & "\n"
      if runtimeConfig.resultsUri.len > 0:
        runtimeConfig.writeResults(resultsJson)
      elif saveScoresPath.len > 0:
        writeFile(saveScoresPath, resultsJson)
      echo "run over: endRule=", sim.endRuleText(), " reason=",
        sim.reasonText(), " rungs=", sim.ledger.milestonesReached(), "/11",
        " score=", sim.ledger.episodeScore(config.maxTicks)
      ## Bounded shutdown grace: the certification runner pings /healthz and
      ## /global AFTER the player pod starts, and a scripted episode can have
      ## written its artifacts by then. Keep answering for a bounded window,
      ## then exit.
      let graceUntil = getMonoTime() +
        initDuration(seconds = ShutdownGraceSeconds)
      while getMonoTime() < graceUntil:
        sleep(200)
      httpServer.close()
      joinThread(serverThread)
      break

    runFrameLimiter(lastTick, config.fastMode and sim.phase == Playing and
      not replayLoaded)
