## The JS wire-constants block: the handful of engine constants the browser
## chrome must agree with (playback speeds, fps, the chrome sprite id).
##
## Forked from `src/ctf/wire_constants.nim`. Historically each HTML client
## re-typed these as literals and nothing enforced agreement - a retuned
## `PlaybackSpeeds` would silently desync every client. This module renders
## them ONCE, from the same Nim consts the engine runs on; `server.nim`
## splices the block into every served client page and
## `tools/gen_wire_constants.nim` emits it for the static wasm bundle.
##
## The object is `window.MINECRAFT_WIRE`, as the fork's rename discipline
## requires, and it is ALSO aliased to `window.CTF_WIRE`: `client/
## chrome_common.js` is inherited BYTE-FOR-BYTE (sha256
## 7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c) and that
## file reads `window.CTF_WIRE`. Editing it to read the new name would break
## the byte pin; the alias satisfies both, and is the one documented
## divergence in `docs/PORTING-MINECRAFT.md` on this point.

import std/strutils

import sim, global

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

const WireConstantsJs* =
  "window.MINECRAFT_WIRE={speeds:" & jsIntArray(PlaybackSpeeds) &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",cell:" & $CellPixels &
  "};window.CTF_WIRE=window.MINECRAFT_WIRE;"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
