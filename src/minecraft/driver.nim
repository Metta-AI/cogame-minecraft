## The driver: the deterministic expansion of a plan into the tick queue.
##
## Forked from `src/ctf/control.nim` (directive -> per-tick actuation),
## retargeted from pixel steering to a PRIMITIVE QUEUE. It is the ONLY
## producer of primitives and it contains no randomness.
##
## The driver never invents an action the schema does not express and never
## produces a step into a cell it believes is lava - but it makes no promise
## about a cell the cog has never seen, which is why walking into the unknown
## costs an explicit `move` or `tunnel`.

import sim, directives

type
  ExpandedPlan* = object
    queue*: seq[Primitive]
    truncated*: bool
    unreachable*: int

proc expandOne(sim: SimServer, action: PlanAction,
    out2: var seq[Primitive], unreachable: var int) =
  let cap = sim.config.macroPrimitiveCap
  case action.kind
  of akPrimitive:
    for _ in 0 ..< min(action.n, cap):
      out2.add(action.primitive)
  of akMove:
    for _ in 0 ..< min(action.n, cap):
      out2.add(action.facing.moveOf())
  of akTunnel:
    ## `n` x (mine, move_<dir>) in that order - 2 primitives per cell. This is
    ## how you move underground.
    var emitted = 0
    for _ in 0 ..< action.n:
      if emitted + 2 > cap:
        break
      out2.add(pMine)
      out2.add(action.facing.moveOf())
      emitted += 2
  of akGoto:
    ## Against the KNOWN map of the cog's current level as of turn start. A
    ## target that is not reachable through known walkable cells yields ZERO
    ## primitives and counts as `unreachable`.
    if action.x == sim.cog.x and action.y == sim.cog.y:
      ## Already standing on it. Zero primitives, but NOT unreachable: the
      ## note scopes `unreachable` to a target the driver cannot path to, and
      ## reporting "I could not get there" for a cell the cog is on would be
      ## a lie in the one field that tells a policy its plan was refused.
      return
    let steps = sim.world.bfsPath(sim.cog.x, sim.cog.y, sim.cog.z,
      action.x, action.y, cap)
    if steps.len == 0:
      inc unreachable
      return
    for facing in steps:
      out2.add(facing.moveOf())

proc expandPlan*(sim: SimServer, plan: Plan): ExpandedPlan =
  ## The whole expanded queue is truncated to `turnTicks` primitives; the
  ## surplus is discarded and reported next turn. NOTHING CARRIES OVER.
  result.queue = @[]
  for action in plan.actions:
    expandOne(sim, action, result.queue, result.unreachable)
  if result.queue.len > sim.config.turnTicks:
    result.queue.setLen(sim.config.turnTicks)
    result.truncated = true

proc primitiveNames*(queue: openArray[Primitive]): seq[string] =
  result = @[]
  for primitive in queue:
    result.add($primitive)
