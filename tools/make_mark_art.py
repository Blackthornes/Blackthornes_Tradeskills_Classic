"""Draw Media/Marks/Marks.tga, the small marks a list puts before what to do
with an item (UI/Marks.lua): a coin for Sell, a letter for Mail, a lock for
Keep and the rest.

    python tools/make_mark_art.py

Drawn here, never shipped from the game. Every mark is white with a thin dark
edge, so the game tints it by colour (SetVertexColor) and one picture serves
every colour, in both window styles. They sit in one 128 by 128 sheet, four
across and four down, each 32 pixels square; UI/Marks.lua knows each one's
place (Marks.CELLS, in the order of MARKS below). Uncompressed 32-bit TGA,
supersampled 8 by 8 per pixel. The same tool in all five Blackthornes addons;
rerun it, never edit the TGA.
"""

import os
import struct

import numpy as np

CELL = 32
COLUMNS = 4
ROWS = 4
SAMPLES = 8
OUTLINE = 1.4

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Media", "Marks")

FILL_TOP = np.array([1.0, 1.0, 1.0])
FILL_BOTTOM = np.array([0.80, 0.80, 0.82])
EDGE = np.array([0.02, 0.02, 0.03])


def polygon(points, x, y):
    """True where (x, y) is inside the polygon (even-odd)."""
    result = np.zeros(x.shape, dtype=bool)
    count = len(points)
    for i in range(count):
        ax, ay = points[i]
        bx, by = points[(i + 1) % count]
        if ay == by:
            continue
        crosses = (ay > y) != (by > y)
        at = ax + (y - ay) / (by - ay) * (bx - ax)
        result ^= crosses & (x < at)
    return result


def disc(cx, cy, r, x, y):
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def ring(cx, cy, inner, outer, x, y):
    d = (x - cx) ** 2 + (y - cy) ** 2
    return (d <= outer * outer) & (d >= inner * inner)


def box(x0, y0, x1, y1, x, y):
    return (x >= x0) & (x <= x1) & (y >= y0) & (y <= y1)


def ellipse(cx, cy, rx, ry, x, y):
    return ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1


def segment(ax, ay, bx, by, width, x, y):
    dx, dy = bx - ax, by - ay
    t = np.clip(((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy), 0, 1)
    return (x - (ax + t * dx)) ** 2 + (y - (ay + t * dy)) ** 2 <= (width / 2) ** 2


# Each mark is a function of the cell's coordinates (0 to 32, y downward)
# that answers where it is filled.

def coin(x, y):
    return disc(16, 16, 11, x, y) & ~ring(16, 16, 6.2, 8.4, x, y)


def letter(x, y):
    body = box(4.5, 8.5, 27.5, 23.5, x, y)
    flap = segment(5, 9, 16, 17.5, 1.8, x, y) | segment(16, 17.5, 27, 9, 1.8, x, y)
    return body & ~flap


def lock(x, y):
    body = box(7.5, 14.5, 24.5, 27.5, x, y)
    shackle = ring(16, 14.5, 4.2, 7, x, y) & (y <= 14.5)
    legs = box(9, 12, 11.8, 14.5, x, y) | box(20.2, 12, 23, 14.5, x, y)
    keyhole = disc(16, 19.5, 1.9, x, y) | box(15.1, 19.5, 16.9, 24, x, y)
    return (body | shackle | legs) & ~keyhole


def star(x, y):
    dx, dy = np.abs(x - 16) / 13.0, np.abs(y - 16) / 13.0
    return np.sqrt(dx) + np.sqrt(dy) <= 1


def bank(x, y):
    roof = polygon([(3.5, 11.5), (16, 3.5), (28.5, 11.5)], x, y)
    beam = box(4.5, 11.5, 27.5, 13.5, x, y)
    columns = np.zeros(x.shape, dtype=bool)
    for left in (6.5, 12, 17.5, 23):
        columns |= box(left, 14.5, left + 2.6, 23.5, x, y)
    base = box(4, 24.5, 28, 28, x, y)
    return roof | beam | columns | base


def upgrade(x, y):
    head = polygon([(16, 3.5), (27.5, 15.5), (4.5, 15.5)], x, y)
    shaft = box(12, 15, 20, 28, x, y)
    return head | shaft


def look(x, y):
    lens = ring(13, 13, 5.6, 9.2, x, y)
    handle = segment(19.6, 19.6, 27, 27, 4.2, x, y)
    return lens | handle


def tag(x, y):
    shape = polygon([(5, 5), (17, 5), (28, 16.5), (16.5, 28), (5, 17)], x, y)
    return shape & ~disc(10.5, 10.5, 2.2, x, y)


def hourglass(x, y):
    top = box(7, 3.5, 25, 6.5, x, y)
    bottom = box(7, 25.5, 25, 28.5, x, y)
    glass = polygon([(9, 6.5), (23, 6.5), (17.3, 16), (23, 25.5), (9, 25.5), (14.7, 16)], x, y)
    return top | bottom | glass


def quest(x, y):
    bar = polygon([(12.5, 3.5), (19.5, 3.5), (18, 20), (14, 20)], x, y)
    return bar | disc(16, 25, 3.2, x, y)


def door(x, y):
    outer = box(7.5, 14, 24.5, 28.5, x, y) | disc(16, 14, 8.5, x, y)
    inner = box(11.5, 14, 20.5, 28.5, x, y) | disc(16, 14, 4.5, x, y)
    return outer & ~inner


def anvil(x, y):
    return polygon([(2, 9), (28.5, 9), (28.5, 15), (21, 15), (19, 20), (24.5, 23),
                    (24.5, 27.5), (7.5, 27.5), (7.5, 23), (13, 20), (11, 15), (8.5, 13.5)], x, y)


def paw(x, y):
    pad = ellipse(16, 21, 6.8, 5.6, x, y)
    toes = (disc(7.5, 13, 3, x, y) | disc(12.5, 7.5, 3, x, y)
            | disc(19.5, 7.5, 3, x, y) | disc(24.5, 13, 3, x, y))
    return pad | toes


def never(x, y):
    circle = ring(16, 16, 8.2, 11.5, x, y)
    slash = segment(8.5, 23.5, 23.5, 8.5, 3.4, x, y) & disc(16, 16, 11.5, x, y)
    return circle | slash


# The order is the sheet's, left to right then down; UI/Marks.lua's CELLS
# keeps the same order.
MARKS = [
    ("coin", coin), ("letter", letter), ("lock", lock), ("star", star),
    ("bank", bank), ("upgrade", upgrade), ("look", look), ("tag", tag),
    ("hourglass", hourglass), ("quest", quest), ("door", door), ("anvil", anvil),
    ("paw", paw), ("never", never),
]


def dilate(mask, steps):
    grown = mask.copy()
    for _ in range(steps):
        shifted = grown.copy()
        shifted[1:, :] |= grown[:-1, :]
        shifted[:-1, :] |= grown[1:, :]
        shifted[:, 1:] |= grown[:, :-1]
        shifted[:, :-1] |= grown[:, 1:]
        grown = shifted
    return grown


def cell(shape):
    size = CELL * SAMPLES
    coords = (np.arange(size) + 0.5) / SAMPLES
    x, y = np.meshgrid(coords, coords)
    fill = shape(x, y)
    edge = dilate(fill, int(round(OUTLINE * SAMPLES))) & ~fill

    shade = (y / CELL)[..., None]
    color = FILL_TOP * (1 - shade) + FILL_BOTTOM * shade
    rgb = np.where(fill[..., None], color, EDGE)
    alpha = (fill | edge).astype(float)

    # Average each pixel's samples, colour weighted by coverage.
    def down(values):
        return values.reshape(CELL, SAMPLES, CELL, SAMPLES, -1).mean(axis=(1, 3))

    a = down(alpha[..., None])
    weighted = down(rgb * alpha[..., None])
    rgb_out = np.where(a > 0, weighted / np.maximum(a, 1e-9), 0)
    return np.concatenate([rgb_out, a], axis=2)


def main():
    sheet = np.zeros((ROWS * CELL, COLUMNS * CELL, 4))
    for index, (_, shape) in enumerate(MARKS):
        row, column = divmod(index, COLUMNS)
        sheet[row * CELL:(row + 1) * CELL, column * CELL:(column + 1) * CELL] = cell(shape)

    pixels = np.clip(np.round(sheet * 255), 0, 255).astype(np.uint8)
    # BGRA, bottom-up rows, the orientation a plain TGA declares.
    bgra = pixels[::-1, :, [2, 1, 0, 3]]
    height, width = pixels.shape[:2]
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, 32, 8)
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "Marks.tga")
    with open(path, "wb") as handle:
        handle.write(header)
        handle.write(bgra.tobytes())
    print("wrote %s (%d bytes)" % (os.path.relpath(path, ROOT), os.path.getsize(path)))


if __name__ == "__main__":
    main()
