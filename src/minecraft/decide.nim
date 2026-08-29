## The decision layer: the per-turn loop that asks the seat what its cog does
## next, and always has an answer.
##
## Forked from `src/ctf/decide.nim`. THE SHAPE IS THE STARTER'S, CARRYING A
## BATCH OF ONE: there is exactly one seat, so the starter's
## one-parallel-batch-per-turn machinery (`engine.client.curl.makeRequests`)
## is untouched and simply carries a single request.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets
## `attempt1Ms`, the single retry gets `retryMs`, the whole turn is wrapped in
## a monotonic `turnBudgetMs` deadline, a rolling 60 s request counter is the
## rate guard, and the budget guard switches the LLM off for the rest of the
## episode the moment two more full turns would not fit inside
## `wallClockBudgetSeconds`. On a second failure the turn's plan becomes the
## `miner` scripted plan - the SAME proc the `miner` baseline uses, imported,
## never duplicated.

import std/[json, monotimes, os, strutils, times]

import curly

import sim, directives, baselines, llm

type
  SeatPolicy* = object
    ## What the seat registered as. A seat that registers with neither field -
    ## or never registers at all - is `miner`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    seats*: seq[SeatPolicy]
    plans*: seq[Plan]
    havePlan*: seq[bool]
    state*: seq[BaselineState]
    params*: BaselineParams
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool
    requestTimes*: seq[MonoTime]
    records*: seq[string]

const RateGuardCeiling* = 28
  ## `turnSpacingMs` pins the steady state at 23 req/min, but a run of
  ## retrying turns issues two requests each. If issuing the next request
  ## would push the trailing-60 s count above this, the turn skips the call
  ## and takes the `miner` plan with `cause = "rate_guard"`. Bounded, logged,
  ## never a sleep on the episode's critical path.

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.client = newLlmClient(sim.config)
  result.params = DefaultBaselineParams
  let seats = sim.seatCount()
  result.seats = newSeq[SeatPolicy](seats)
  result.plans = newSeq[Plan](seats)
  result.havePlan = newSeq[bool](seats)
  result.state = newSeq[BaselineState](seats)
  result.requestTimes = @[]
  for i in 0 ..< seats:
    result.seats[i].baseline = blMiner
    result.seats[i].label = "miner"
    result.state[i] = initBaselineState()

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm:
    "llm"
  else:
    "scripted"

proc minerFallback*(engine: var DecisionEngine, sim: SimServer,
    seat: int): Plan =
  ## The server-side fallback IS the `miner` baseline proc. One source, so the
  ## two cannot drift.
  result = minerPlan(sim, engine.params, engine.state[seat])
  result.source = dsFallback

proc scriptedFor*(engine: var DecisionEngine, sim: SimServer,
    seat: int): Plan =
  baselinePlan(sim, engine.seats[seat].baseline, engine.params,
    engine.state[seat])

proc rateGuardBlocked*(engine: var DecisionEngine): bool =
  ## The rolling 60 s request counter.
  let now = getMonoTime()
  var kept: seq[MonoTime] = @[]
  for stamp in engine.requestTimes:
    if (now - stamp).inSeconds.int < 60:
      kept.add(stamp)
  engine.requestTimes = kept
  engine.requestTimes.len >= RateGuardCeiling

proc turn*(engine: var DecisionEngine, sim: SimServer, turnIndex: int,
    elapsedSeconds: int): seq[string] =
  ## Runs ONE decision turn and installs the seat's plan. Returns the replay
  ## chat records this turn produced. Never raises: every failure path ends in
  ## a legal plan.
  result = @[]
  let
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
  engine.client.throttled = false

  # --- budget guard: settle EARLY rather than overrun ----------------------
  if not engine.llmOff:
    let turnSeconds = (sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(turnIndex,
        max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "minecraft: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  var open: seq[int] = @[]
  for seat in 0 ..< engine.seats.len:
    if engine.seats[seat].isLlm and not engine.llmOff and
        not engine.client.disabled and not engine.rateGuardBlocked():
      open.add(seat)
    elif engine.seats[seat].isLlm:
      ## An LLM seat that CANNOT call the LLM this turn is a FALLBACK, not a
      ## scripted policy, and the design's `fallback.cause` enum names every
      ## reason it happens. Recording it is what makes the two countable.
      var plan = engine.minerFallback(sim, seat)
      engine.plans[seat] = plan
      engine.havePlan[seat] = true
      ## The cause chain is ordered by which guard actually stopped the call
      ## this turn, not by which is easiest to detect: the rate guard is
      ## evaluated before the credential check above, so it is named first
      ## here too. A fallback whose cause is wrong is worse than none - it is
      ## what makes a hosted log unreadable.
      let cause =
        if engine.llmOff: "budget_guard"
        elif engine.rateGuardBlocked(): "rate_guard"
        elif engine.client.disabled: "no_credentials"
        else: "transport_error"
      result.add(fallbackRecord(turnIndex, 1, cause,
        "the LLM is unavailable for this turn; playing the miner plan"))
      echo "minecraft llm: seat ", seat, " falling back to miner (", cause,
        ") on turn ", turnIndex
    else:
      var plan = engine.scriptedFor(sim, seat)
      plan.source = dsScripted
      engine.plans[seat] = plan
      engine.havePlan[seat] = true

  # --- the rate floor ------------------------------------------------------
  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  # --- up to two batches (of one: there is one seat) -----------------------
  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      for seat in open:
        result.add(fallbackRecord(turnIndex, attempt + 1, "timeout",
          "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var batch: RequestBatch
    for seat in open:
      var user = $sim.observationJson(turnIndex, includeNotes = true)
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{', with an " &
          "\"actions\" array.")
      let request = engine.client.requestFor(
        SystemPrompt, userMessage(engine.seats[seat].prompt, user))
      batch.post(request.url, request.headers, request.body, $seat)
      engine.requestTimes.add(getMonoTime())
    let started = getMonoTime()
    ## curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    ## SECONDS, so this conversion FLOORS - and sim_config REJECTS a config
    ## that is not a whole number of seconds, so the floor is an identity.
    let responses = engine.client.curl.makeRequests(batch,
      max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int] = @[]
    for position, seat in open:
      var cause = "parse_error"
      try:
        let text = engine.client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        var plan = parsePlan(extractJsonObject(withPrefill(text)),
          sim.config.maxActionsPerTurn, sim.config.levelSize)
        plan.source = dsLlm
        plan.latencyMs = latency
        engine.plans[seat] = plan
        engine.havePlan[seat] = true
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          cause = "throttled"
        result.add(fallbackRecord(turnIndex, attempt + 1, cause, error.msg))
        ## Attempt 1 says "will retry"; only a genuine SECOND failure logs
        ## "falling back" (the phrase phase 60 greps the game log for).
        echo "minecraft llm: seat ", seat, " attempt ", attempt + 1,
          " failed, will retry: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      ## FAIL FAST: the only model left answered 429, so the retry would be
      ## refused the same way. Spend the rest of the turn on the scripted
      ## layer instead of on a call that cannot land.
      echo "minecraft llm: provider throttled with no other candidate; ",
        open.len, " seat(s) fall back for turn ", turnIndex
      break

  for seat in open:
    var plan = engine.minerFallback(sim, seat)
    engine.plans[seat] = plan
    engine.havePlan[seat] = true
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(turnIndex, 2, cause,
      "seat fell back to the miner plan"))
    echo "minecraft llm: seat ", seat, " falling back to miner (", cause,
      ") on turn ", turnIndex

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record: the episode's whole results document,
  ## written once into the replay chat stream at episode end. It is what makes
  ## the replay SELF-SUFFICIENT - without it the outcome exists only at
  ## COGAME_RESULTS_URI, which a spectator holding the bytes cannot read. The
  ## document is already valid JSON, so it is embedded verbatim rather than
  ## re-parsed: nothing on the path to the artifact writes may raise.
  "{\"k\":\"result\",\"results\":" & sim.runResultsJson() & "}"

proc turnStartRecord*(turn, tick, ticksLeft: int): string =
  $(%*{"k": "turn", "n": turn, "tick": tick, "ticks_left": ticksLeft})
