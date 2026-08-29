## The minecraft player container: a policy is just a prompt.
##
## This process is DELIBERATELY thin. It connects to its seat, sends ONE
## Sprite v1 chat message carrying its registration, and then only receives.
## Every decision happens inside the GAME server, because that is the only
## container the platform injects the `anthropic_api_key` coworld secret into,
## and because keeping the decision layer server-side is what makes the
## recorded primitive log reproducible with no network in the loop.
##
##   PLAYER_PROMPT        a strategy in plain English -> this seat is an LLM seat
##   PLAYER_SCRIPTED      miner | scrounger           -> this seat is scripted
##   PLAYER_POLICY_LABEL  a free label for the replay's `register` record
##
## A seat that sets neither is `miner`. To field your own policy, reuse this
## image and set PLAYER_PROMPT:
##
##   coworld upload-policy <minecraft-image> --name my-minecraft \
##     --run /bin/minecraft-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils, unicode],
  bitworld/spriteprotocol,
  whisky

const
  ConnectAttempts = 240      ## 240 x 500 ms = 2 minutes of dialling.
  ConnectRetryMs = 500
  RegistrationResends = 10   ## re-sends after the first, ~1 s apart.
  ResendEveryFrames = 24     ## ~1 s of frames at 24 Hz.
  ReconnectAttempts = 6
  MaxPromptRunes = 4000
  MaxLabelRunes = 64

proc truncateRunes(text: string, limit: int): string =
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc registrationBlob(prompt, scripted, policy: string): string =
  ## The one registration message. `scripted` is JSON null when the seat is an
  ## LLM seat, so the server can tell "no baseline named" from "miner named
  ## explicitly".
  var node = %*{
    "type": "register",
    "prompt": prompt.truncateRunes(MaxPromptRunes),
    "policy": policy.truncateRunes(MaxLabelRunes)
  }
  if scripted.len > 0:
    node["scripted"] = %scripted
  else:
    node["scripted"] = newJNull()
  blobFromSpriteChat($node)

proc readyBlob(): string =
  ## The Sprite v1 player-ready packet (0x85). Legitimate here in a way it is
  ## not for an ordinary player client: this seat sends NO inputs at all (the
  ## server computes every primitive), so the dead-reckoning hazard cannot
  ## arise, and a fastMode server can advance as soon as the seat acknowledges
  ## the frame.
  result = newString(1)
  result[0] = char(0x85)

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let
    prompt = getEnv("PLAYER_PROMPT").strip()
    scripted = getEnv("PLAYER_SCRIPTED").strip()
    label = block:
      let explicit = getEnv("PLAYER_POLICY_LABEL").strip()
      if explicit.len > 0: explicit
      elif prompt.len > 0: "prompt"
      elif scripted.len > 0: scripted
      else: "miner"
  echo "minecraft player: kind=",
    (if prompt.len > 0: "llm" else: "scripted"),
    " baseline=", (if scripted.len > 0: scripted else: "miner"),
    " label=", label

  proc dial(attempts: int): WebSocket =
    ## Bounded dialling. The game bakes its board tile bed BEFORE it opens the
    ## listener, and the episode runner starts the player at the same instant
    ## as the game - so the first dial always lands on a closed port.
    for attempt in 0 ..< attempts:
      try:
        return newWebSocket(url)
      except CatchableError as error:
        if attempt == 0:
          echo "minecraft player: game not listening yet (", error.msg,
            "); retrying"
        sleep(ConnectRetryMs)
    nil

  var socket = dial(ConnectAttempts)
  if socket == nil:
    quit("minecraft player: game never accepted a connection", 1)
  echo "minecraft player: connected"

  ## Each session is wrapped: whisky's `receiveMessage` RAISES on a close
  ## frame or a truncated read (only a timeout returns none), and mummy's
  ## `send` only QUEUES - so the game's own exit can outrun the flushed frame.
  ## A naive player exits 1 on that race and fails certification
  ## intermittently (cogame-raid 0.1.3). EXITING 0 ON A DEAD SOCKET is the fix.
  ##
  ## REGISTRATION IS RE-SENT, NOT SENT ONCE: the lobby sends frames to a
  ## socket before it has been admitted, so a single registration can land
  ## while the seat has no index yet. The server HOLDS an unappliable
  ## registration and this end keeps re-sending it for the first ~10 s of
  ## frames. Registering twice is harmless: the server re-reads the same
  ## fields and writes only one `register` record.
  var reconnects = 0
  while true:
    var sessionFrames = 0
    try:
      socket.send(registrationBlob(prompt, scripted, label), BinaryMessage)
      var resends = 0
      while true:
        let received = socket.receiveMessage()
        if received.isNone:
          continue                    ## a read timeout, not a closed socket
        inc sessionFrames
        if resends < RegistrationResends and
            sessionFrames mod ResendEveryFrames == 1:
          inc resends
          socket.send(registrationBlob(prompt, scripted, label), BinaryMessage)
        socket.send(readyBlob(), BinaryMessage)
    except CatchableError as error:
      echo "minecraft player: socket closed (", error.msg, ")"
    if sessionFrames == 0 or reconnects >= ReconnectAttempts:
      break
    inc reconnects
    echo "minecraft player: re-dialling the seat (attempt ", reconnects, ")"
    socket = dial(ReconnectAttempts)
    if socket == nil:
      echo "minecraft player: game is no longer listening, exiting cleanly"
      break
    echo "minecraft player: reconnected, re-registering"
  quit(0)
