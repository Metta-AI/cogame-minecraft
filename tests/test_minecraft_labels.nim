## The board-label vocabulary contract.
##
## Design note §Tests item 46, the starter's `test_label_contract` pattern: the
## emitted board-label vocabulary must equal `tests/label_manifest.txt`,
## regenerated in the same commit as any label change.
##
##   nim r --path:src tests/test_minecraft_labels.nim --write

import std/[os, strutils]

import minecraft/labels

let emitted = boardLabelVocabulary()
const ManifestPath = "tests/label_manifest.txt"

if paramCount() >= 1 and paramStr(1) == "--write":
  writeFile(ManifestPath, emitted.join("\n") & "\n")
  echo "wrote ", ManifestPath, " (", emitted.len, " labels)"
else:
  doAssert fileExists(ManifestPath), ManifestPath & " is missing"
  var pinned: seq[string] = @[]
  for line in readFile(ManifestPath).splitLines():
    if line.strip().len > 0:
      pinned.add(line.strip())
  if pinned != emitted:
    var added: seq[string] = @[]
    var gone: seq[string] = @[]
    for label in emitted:
      if label notin pinned:
        added.add(label)
    for label in pinned:
      if label notin emitted:
        gone.add(label)
    echo "added: ", added
    echo "removed: ", gone
    doAssert false, "the label vocabulary changed; regenerate " &
      ManifestPath & " in the same commit " &
      "(nim r --path:src tests/test_minecraft_labels.nim --write)"
  echo "ok: ", emitted.len, " board labels match ", ManifestPath

echo "test_minecraft_labels: PASS"
