#!/usr/bin/env python3
"""Split the two nano-banana source sheets into the board sprites the viewer
bakes from.

The sources under ``tools/art/source/`` are single ``gemini-2.5-flash-image``
renders (see ``coworld-builder/playbooks/art-nanobanana.md``): one sheet per
character family keeps the style consistent across every sprite, and one
render is cheaper and more coherent than one call per tile.

  cog_sheet.png     four Softmax cogs in a miner's kit (head-lamp + pickaxe),
                    on a flat #00FF00 chroma backdrop -> data/art/cog_*.png
  blocks_sheet.png  a 4x4 grid of top-down terrain tiles on a flat #FF00FF
                    chroma backdrop                    -> data/art/tile_*.png

Both outputs are COMMITTED: CI never regenerates art. Re-run this script only
when a sheet is re-rendered.

    python3 tools/art/split_sheets.py

Requires Pillow.
"""

import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SOURCE = os.path.join(HERE, "source")
OUT = os.path.join(REPO, "data", "art")

# The 4x4 tile grid of blocks_sheet.png, in reading order.
TILES = [
    "grass", "sand", "water", "tree",
    "stone", "coal_ore", "iron_ore", "diamond_ore",
    "tunnel", "lava", "table", "bedrock",
    "furnace", "shaft_down", "shaft_up", "stone_alt",
]

COG_FACINGS = ["north", "east", "south", "west"]

TILE_SIZE = 48
COG_SIZE = 48


def border_median(image):
    """The backdrop colour, as the median of the border pixels.

    Corners sometimes carry a smudge and the "pure" chroma the model was asked
    for comes back as *some* chroma with a tinted edge, so a single corner
    sample keys badly.
    """
    pixels = image.load()
    w, h = image.size
    samples = []
    for x in range(w):
        samples.append(pixels[x, 0][:3])
        samples.append(pixels[x, h - 1][:3])
    for y in range(h):
        samples.append(pixels[0, y][:3])
        samples.append(pixels[w - 1, y][:3])
    channels = []
    for i in range(3):
        values = sorted(s[i] for s in samples)
        channels.append(values[len(values) // 2])
    return tuple(channels)


def key_out(image, backdrop, tolerance=70):
    """Flood-fill the backdrop from the border so chroma-coloured detail
    INSIDE a sprite survives."""
    image = image.convert("RGBA")
    w, h = image.size
    pixels = image.load()

    def near(px):
        return (abs(px[0] - backdrop[0]) + abs(px[1] - backdrop[1])
                + abs(px[2] - backdrop[2])) <= tolerance

    stack = []
    for x in range(w):
        stack.append((x, 0))
        stack.append((x, h - 1))
    for y in range(h):
        stack.append((0, y))
        stack.append((w - 1, y))
    seen = bytearray(w * h)
    while stack:
        x, y = stack.pop()
        if x < 0 or y < 0 or x >= w or y >= h:
            continue
        idx = y * w + x
        if seen[idx]:
            continue
        seen[idx] = 1
        if not near(pixels[x, y]):
            continue
        pixels[x, y] = (0, 0, 0, 0)
        stack.append((x + 1, y))
        stack.append((x - 1, y))
        stack.append((x, y + 1))
        stack.append((x, y - 1))
    return image


def content_bbox(image):
    box = image.getbbox()
    return box if box else (0, 0, image.size[0], image.size[1])


def pad_square(image, size):
    box = content_bbox(image)
    cropped = image.crop(box)
    side = max(cropped.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(cropped, ((side - cropped.size[0]) // 2,
                           (side - cropped.size[1]) // 2))
    return square.resize((size, size), Image.LANCZOS)


def split_row(image, count):
    """Split a keyed row on empty columns."""
    w, h = image.size
    alpha = image.split()[3].load()
    occupied = []
    for x in range(w):
        hit = False
        for y in range(0, h, 2):
            if alpha[x, y] > 12:
                hit = True
                break
        occupied.append(hit)
    runs = []
    start = None
    for x in range(w):
        if occupied[x] and start is None:
            start = x
        elif not occupied[x] and start is not None:
            runs.append((start, x))
            start = None
    if start is not None:
        runs.append((start, w))
    runs = [r for r in runs if r[1] - r[0] > w // (count * 6)]
    runs.sort(key=lambda r: r[0])
    if len(runs) != count:
        # Fall back to an even split: the model sometimes lets a lamp beam
        # bridge two panels, which merges their column runs.
        step = w // count
        runs = [(i * step, (i + 1) * step) for i in range(count)]
    return [image.crop((r[0], 0, r[1], h)) for r in runs]


def strip_green(image, factor=1.18):
    """Drop every strongly GREEN-dominant pixel.

    The cog render's head-lamp throws a wide beam of translucent yellow-green
    over the chroma backdrop. The beam is a different green from the backdrop,
    so the border flood-fill stops at its edge and leaves a green wedge above
    every head. The cog itself is red, steel and cyan and carries no
    green-dominant pixel at all, so a hue test removes the beam and touches
    nothing else.
    """
    image = image.convert("RGBA")
    pixels = image.load()
    w, h = image.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue
            if g > r * factor and g > b * factor:
                pixels[x, y] = (0, 0, 0, 0)
    return image


def split_cogs():
    path = os.path.join(SOURCE, "cog_sheet.png")
    image = Image.open(path)
    keyed = strip_green(key_out(image, border_median(image)))
    box = content_bbox(keyed)
    row = keyed.crop(box)
    parts = split_row(row, len(COG_FACINGS))
    for facing, part in zip(COG_FACINGS, parts):
        pad_square(part, COG_SIZE).save(
            os.path.join(OUT, "cog_%s.png" % facing))
    # The scorebug plate avatar and the agent-view caption use the same render
    # at a larger size.
    pad_square(parts[0], 96).save(os.path.join(OUT, "cog_avatar.png"))
    print("cogs: %d sprites" % (len(parts) + 1))


def split_tiles():
    path = os.path.join(SOURCE, "blocks_sheet.png")
    image = Image.open(path)
    keyed = key_out(image, border_median(image))
    box = content_bbox(keyed)
    grid = keyed.crop(box)
    w, h = grid.size
    cw, ch = w / 4.0, h / 4.0
    for index, name in enumerate(TILES):
        col, rowIndex = index % 4, index // 4
        cell = grid.crop((int(col * cw), int(rowIndex * ch),
                          int((col + 1) * cw), int((rowIndex + 1) * ch)))
        # Trim the inter-tile gutter, then square and resize: every tile the
        # board draws is the same TILE_SIZE.
        cell = key_out(cell.convert("RGBA"), border_median(cell), tolerance=40)
        cell = cell.crop(content_bbox(cell))
        flat = Image.new("RGBA", cell.size, (0, 0, 0, 255))
        flat.alpha_composite(cell)
        flat.resize((TILE_SIZE, TILE_SIZE), Image.LANCZOS).save(
            os.path.join(OUT, "tile_%s.png" % name))
    print("tiles: %d sprites" % len(TILES))


def main():
    os.makedirs(OUT, exist_ok=True)
    if not os.path.isdir(SOURCE):
        print("missing %s" % SOURCE, file=sys.stderr)
        return 1
    split_cogs()
    split_tiles()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
