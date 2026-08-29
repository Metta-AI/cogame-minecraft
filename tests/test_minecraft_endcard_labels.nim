## The endcard and chrome label re-mapping.
##
## Design note §Tests item 45. A forked ctf endcard silently ships paintbot's
## vocabulary - nothing in the starter's tests, in `viewer_smoke.mjs` or in the
## label manifest covers SPECTATOR chrome strings, because `labels.nim`
## deliberately scopes itself to the POLICY contract. The re-labelings are
## therefore enumerated here and enforced.
##
## SCOPE, stated so nobody mistakes it for a weaker check than the design note
## asked for: the design's forbidden-vocabulary sweep is applied to the
## SPECTATOR-VISIBLE STRINGS - the text nodes, titles, aria-labels and captions
## a viewer actually reads - not to every identifier in the inherited page.
## `client/chrome_common.js` is pinned BYTE-FOR-BYTE and the starter's page is
## inherited, so `teamCol`, `activeTeams`, `.ec-tname` and friends necessarily
## survive as CODE; rewriting them would break the very provenance the pin
## exists to protect. Recorded in docs/PORTING-MINECRAFT.md.

import std/[strutils]

let page = readFile("client/replay_broadcast.html")

proc visibleStrings(html: string): seq[string] =
  ## Text nodes plus the attributes a spectator reads (title, aria-label,
  ## alt), with `<style>` and `<script>` bodies excluded.
  result = @[]
  var i = 0
  while i < html.len:
    if html[i] == '<':
      let close = html.find('>', i)
      if close < 0:
        break
      let tag = html[i + 1 ..< close]
      let lower = tag.toLowerAscii()
      if lower.startsWith("script") or lower.startsWith("style"):
        let endTag = if lower.startsWith("script"): "</script>" else: "</style>"
        let stop = html.find(endTag, close)
        i = if stop < 0: html.len else: stop + endTag.len
        continue
      if lower.startsWith("!--"):
        let stop = html.find("-->", i)
        i = if stop < 0: html.len else: stop + 3
        continue
      for attr in ["title=\"", "aria-label=\"", "alt=\""]:
        var a = lower.find(attr)
        while a >= 0:
          let start = i + 1 + a + attr.len
          let stop = html.find('"', start)
          if stop > start:
            result.add(html[start ..< stop])
          a = lower.find(attr, a + 1)
      i = close + 1
      continue
    let next = html.find('<', i)
    let stop = if next < 0: html.len else: next
    let text = html[i ..< stop].strip()
    if text.len > 0:
      result.add(text)
    i = stop

let visible = visibleStrings(page)

block forbiddenVocabulary:
  const Forbidden = ["Lives", "LIVES", "Clstr", "Cap<", "flag", "heart",
    "paint", "hopper", "hill", "POV", "EYES", "spray", "grenade", "med kit",
    "kill"]
  var offenders: seq[string] = @[]
  for text in visible:
    let lower = text.toLowerAscii()
    for word in Forbidden:
      if word.toLowerAscii() in lower:
        offenders.add(word & " in: " & text)
  doAssert offenders.len == 0,
    "paintbot vocabulary survived in a spectator-visible string:\n" &
    offenders.join("\n")
  echo "ok: zero paintbot words in ", visible.len, " spectator-visible strings"

block replacements:
  const Required = [
    "Generating the world&hellip;",
    "Waiting for the cog",
    "Replay hash mismatch — showing recorded actions",
    "AGENT VIEW 11&times;11",
    "MILESTONE TIMELINE",
    "15 CELLS",
    "Spoilers: milestones and the ending on the timeline ahead of the playhead (o)",
    "Cog workshop &middot; Loading replay"
  ]
  for text in Required:
    let count = page.count(text)
    doAssert count == 1,
      "the re-mapped string \"" & text & "\" appears " & $count &
      " times, expected exactly once"
  echo "ok: each re-mapped spectator string is present exactly once"

block endcardColumns:
  # The endcard's own header row, re-mapped from the starter's K/D/Clstr/Cap.
  doAssert "<span>#</span><span>Milestone</span>" in page
  doAssert "<span>Points</span><span>Tick</span><span>Level</span>" in page
  doAssert "THE RUN" in page, "the endcard section head"
  doAssert "ALPHA" in page, "the seat's alias on the plate"
  echo "ok: the endcard header row is the milestone ladder"

echo "test_minecraft_endcard_labels: PASS"
