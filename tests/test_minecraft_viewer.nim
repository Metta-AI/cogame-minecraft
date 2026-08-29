## Viewer provenance and the 360 px rules.
##
## Design note §Tests items 38-44. These are static assertions over the shipped
## client files: the chrome is INHERITED, and a rewrite that reuses the
## starter's ids is a defect, not an improvement.

import std/[algorithm, os, sequtils, strutils]


const
  ChromeCommonSha256 =
    "7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c"
  SpliceBanner = "MINECRAFT additions to the inherited coworld-ctf chrome"

let
  page = readFile("client/replay_broadcast.html")
  core = readFile("client/broadcast_core.js")
  chrome = readFile("client/chrome_common.js")

proc prefixOf(text, marker: string): string =
  let index = text.find(marker)
  doAssert index > 0, "splice banner not found"
  text[0 ..< index]

let prefix = page.prefixOf(SpliceBanner)
let block1 = page[page.find(SpliceBanner) .. ^1]

# 38. `chrome_common is byte-identical`
block chromeCommonIsInherited:
  # The sha256 is pinned as a literal in ci.yml's `test` job (sha256sum), and
  # the size + the module contract are pinned here so a reformat is caught
  # even where no sha tool is on the path.
  doAssert chrome.len == 40022,
    "client/chrome_common.js is " & $chrome.len &
    " bytes; the inherited file is 40022 (sha256 " & ChromeCommonSha256 & ")"
  doAssert chrome.startsWith("'use strict';"), "chrome_common.js was edited"
  doAssert "window.ChromeCommon = function (ctx) {" in chrome
  doAssert "markBeat" in chrome and "renderTransport" in chrome
  doAssert "ingestBeats" in chrome and "renderMomentum" in chrome
  doAssert "ingestLullSpans" in chrome and "renderClock" in chrome
  echo "ok: chrome_common.js is inherited byte-for-byte"

# 39. `broadcast html is starter plus block`
block starterPlusBlock:
  doAssert prefix.len > 200_000,
    "the inherited prefix is the whole starter page, not a stub"
  doAssert block1.len < prefix.len, "the game block only APPENDS"
  # the starter's structure survives
  for id in ["viewport", "stage", "board", "lightpool", "grain", "lockerroom",
      "lk-bg", "lk-art", "lk-sprites", "lk-cap", "chrome", "scorebug",
      "plates-l", "plates-r", "clock", "clock-time", "clock-caption",
      "ffwd-mini", "fpv", "fpv-canvas", "fpv-hud", "fpv-name", "fpv-cap",
      "fpv-grip", "bannerlane", "killfeed", "mmwarn", "transport",
      "btn-restart", "btn-back", "btn-play", "btn-fwd", "btn-end", "btn-loop",
      "btn-skip", "btn-spoilers", "ffwd-chip", "win-chip", "tick-clock",
      "speedchips", "scrub", "momentum", "scrub-fill", "lulls", "scrub-win",
      "scrub-head", "endcard", "ec-headline", "ec-wincond", "ec-how",
      "ec-teams", "ec-replay", "status"]:
    doAssert "id=\"" & id & "\"" in prefix, "the starter's #" & id & " is gone"
  # relayout() and the transport are the starter's
  doAssert "function relayout()" in prefix
  doAssert "setProperty('--hudscale'" in prefix
  doAssert "setProperty('--band'" in prefix
  doAssert "setProperty('--topband'" in prefix
  # broadcast_core's kept procs, function by function
  for fn in ["function clampView()", "function computeFit()",
      "function zoomAt(", "function setZoom(", "function panBy(",
      "function panByMap(", "function panTo(", "function resetView()",
      "function attachMinimap(", "function drawMinimap()",
      "function pushFeed(", "function banner("]:
    doAssert fn in core or fn in prefix,
      "the starter's " & fn & " was not kept"
  echo "ok: the page is the starter's plus an appended block"

# 40. `no shadowed chrome aliases`
block noShadowedAliases:
  # Every name the chrome alias block declares must NOT be re-declared in the
  # appended game block (the cogame-tandem hoisting trap).
  var aliases: seq[string] = @[]
  for line in prefix.splitLines():
    let trimmed = line.strip()
    if not trimmed.startsWith("var "):
      continue
    if "C." notin trimmed:
      continue
    for part in trimmed[4 .. ^1].split(','):
      let name = part.split('=')[0].strip()
      if name.len > 0 and name.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '$'}):
        aliases.add(name)
  doAssert aliases.len > 5, "the alias list was not found"
  doAssert "markBeat" in aliases
  doAssert "(function () {\n  'use strict';" in block1,
    "the game block must live in its own IIFE"
  for name in aliases:
    # `$` is the one name the starter's own appended block re-declares inside
    # its IIFE, and an IIFE-local `$` cannot shadow anything outside it. Every
    # OTHER alias is checked, because the trap is a hoisted `var` in the same
    # scope silently swallowing a game-block function of the same name.
    if name == "$":
      continue
    doAssert ("function " & name & "(") notin block1,
      "the game block shadows the chrome alias " & name
    doAssert ("var " & name & " =") notin block1,
      "the game block shadows the chrome alias " & name
  doAssert "function mcBeat(" in block1, "the beat builder is mcBeat"
  doAssert "markBeat(" notin block1, "the game block never calls markBeat"
  echo "ok: no game-block identifier shadows a chrome alias (", aliases.len,
    " checked)"

# 41. `beat CSS matches emitted kinds`
block beatCss:
  var kinds: seq[string] = @[]
  var index = 0
  while true:
    index = block1.find(".beat-marker.", index)
    if index < 0:
      break
    index += ".beat-marker.".len
    var name = ""
    while index < block1.len and block1[index] in {'a'..'z', '0'..'9'}:
      name.add(block1[index])
      inc index
    if name.len > 0:
      kinds.add(name)
  kinds = kinds.deduplicate()
  kinds.sort()
  doAssert kinds == @["death", "end", "fallback", "milestone", "newdepth"],
    "the beat CSS kinds are " & $kinds
  for gone in ["kill", "steal", "return", "capture", "gamestart", "hillflip",
      "tagout", "gameover"]:
    doAssert (".beat-marker." & gone) notin block1,
      "the starter's " & gone & " beat CSS survived"
  echo "ok: the beat CSS is exactly the five kinds the sim emits"

# 42. `viewpanel is kept and wired`
block viewpanelKept:
  for id in ["viewpanel", "minimap", "minimap-canvas", "zoombar", "zoom-in",
      "zoom-out", "zoom-slider", "zoom-read"]:
    doAssert "id=\"" & id & "\"" in prefix,
      "#" & id & " must be KEPT: the board is much larger than the frame"
  doAssert "core.attachMinimap($('minimap-canvas'))" in prefix
  doAssert "CAMERA_CELLS = 15" in block1
  # The follow-cam is pinned as an EXACT expression, the way the note's closed
  # form `core.setZoom(32 / cameraCells)` was: a bare `core.setZoom(` matches
  # ANY zoom call, so it guards nothing. The mechanism is a convergence loop
  # rather than the closed form because the closed form is only right when the
  # board fits on its width (docs/PORTING-MINECRAFT.md, divergence I).
  doAssert "var cellsNow = t.visW > 0 ? t.visW / 24 : CAMERA_CELLS;" in block1,
    "the follow-cam reads the cell span back from the transform the core REPORTS"
  doAssert "if (followArmed && Math.abs(cellsNow - CAMERA_CELLS) > 0.5) {" in
    block1, "the follow-cam corrects only while it is off target"
  doAssert "core.setZoom((t.zoom || 1) * (cellsNow / CAMERA_CELLS));" in block1,
    "the follow-cam converges on exactly CAMERA_CELLS cells across"
  doAssert "core.panTo(" in block1, "the follow-cam pans every frame"
  doAssert "followArmed" in block1
  # the inset lives in the RIGHT gutter, under the kept minimap
  doAssert "#fpv {" in block1, "the game block re-anchors the inset"
  # ...and the removed ids appear NOWHERE
  for gone in ["povBadge", "fpv-hp", "fpv-gear", "fpv-map", "fpv-map-canvas"]:
    doAssert ("id=\"" & gone & "\"") notin page,
      "#" & gone & " should have been removed"
    doAssert ("$('" & gone & "')") notin page,
      "the JS that fed #" & gone & " should have been removed"
  echo "ok: #viewpanel is kept and wired; the removed ids are gone"

# 43. `transport, endcard and 360 px rules`
block transportAndTinyRules:
  doAssert "#endcard {" in prefix
  doAssert "bottom: var(--band, 0px)" in prefix,
    "the endcard must stop at the transport band"
  doAssert "$('endcard').classList.remove('on')" in prefix,
    "every seek must dismiss the endcard"
  # No game-block element is positioned INSIDE the transport band: every
  # stage-level panel the block adds anchors ABOVE var(--band).
  for panel in ["#mc-left {", "#mc-inv {"]:
    let start = block1.find(panel)
    doAssert start > 0, panel & " is missing"
    let body = block1[start ..< block1.find("}", start)]
    doAssert "position: absolute" in body, panel & " must be stage-anchored"
    doAssert "var(--band" in body,
      panel & " must anchor above the transport band, never inside it"
  doAssert "position: fixed" notin block1,
    "a fixed overlay escapes the stage and can land in the band"
  # the plate name rule
  doAssert ".plate-name {" in block1
  doAssert "flex: 1 1 auto;" in block1
  doAssert "min-width: 3.2em;" in block1
  # the six .tiny rules
  var tinyRules = 0
  for line in block1.splitLines():
    if line.strip().startsWith("#stage.tiny"):
      inc tinyRules
  doAssert tinyRules >= 6, "only " & $tinyRules & " .tiny rules"
  # both gutter arithmetics
  doAssert "10 + 4 + 106 = 120" in block1, "the left gutter arithmetic"
  doAssert "56 + 8 + 56 = 120" in block1, "the right gutter arithmetic"
  doAssert "width: 56px; height: 56px" in block1
  doAssert "#stage.tiny #fpv-grip { display: none; }" in block1
  doAssert "#stage.tiny #zoombar { display: none; }" in block1
  echo "ok: the transport, the endcard and the six 360 px rules"

# 44. `no canvas text on the board layer`
block noCanvasTextOnTheBoard:
  for forbidden in ["fillText", "strokeText"]:
    doAssert forbidden notin block1,
      "the game block draws " & forbidden & " - every string in this viewer " &
      "is DOM chrome or lives in a fixed-size gutter panel"
  # broadcast_core is a sprite compositor: it must not draw text either
  doAssert "fillText" notin core
  doAssert "strokeText" notin core
  echo "ok: no canvas text anywhere on the board draw path"

block staticReplayShellIsOneStarter:
  let shell = readFile("replay-viewer/static_replay.js")
  let worker = readFile("replay-viewer/static_replay_worker.js")
  let flags = readFile("replay-viewer/config.nims")
  # The shell and the link flags are a MATCHED PAIR from ONE starter.
  doAssert "Module.onRuntimeInitialized" in worker,
    "coworld-ctf's shell waits for onRuntimeInitialized"
  doAssert "MODULARIZE" notin flags,
    "a MODULARIZE build needs a factory call the paintbot shell never makes"
  doAssert "EXPORT_NAME" notin flags
  doAssert "-s ABORTING_MALLOC=1" in flags
  doAssert "-s ALLOW_MEMORY_GROWTH" in flags
  doAssert "--preload-file" in flags
  doAssert "_minecraft_load_replay" in flags and "_minecraft_frame" in flags
  doAssert "importScripts('./wire_constants.js', './broadcast_core.js', " &
    "'./minecraft_replay.js')" in worker
  # the load and error signals
  doAssert "'data-replay-loaded', 'true'" in shell
  doAssert "'data-replay-error'" in shell
  doAssert "ctf" notin worker and "ctf" notin shell,
    "a stray ctf_ export would call into nothing"
  # The PAGE must look for the adapter under the name the shell publishes.
  # A half-done rename here is silent: the page falls through to
  # window.BroadcastCore, which the static bundle does not load, and the viewer
  # sits on "CONNECTING" forever with every file 200 (run 33240668656).
  doAssert "window.MinecraftStaticReplay = {" in shell
  doAssert "window.CtfStaticReplay" notin page
  doAssert page.count("window.MinecraftStaticReplay") == 3,
    "the page reads the adapter name in three places: the bundle detector, " &
    "the art base and the core factory"
  echo "ok: shell, worker and link flags all come from coworld-ctf"

echo "test_minecraft_viewer: PASS"
