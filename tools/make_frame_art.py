"""Draw Media/Frame/*.tga, the Titanforged window art: the corner pieces with
their gems, the round portrait and the light that runs round it, the addon's
emblem, the title plate, the close gem and a soft glow.

    python tools/make_frame_art.py

The window's straight edges are not textures: Theme.Titanforged draws them
from colour gradients, so they stay sharp at any size. Only the shapes a
gradient cannot make live here.

Like tools/make_star.py: uncompressed 32-bit TGA with power-of-two sides,
supersampled 4x4 per pixel. Every shape is a polygon, a circle or a band, so
the whole set can be adjusted by changing a number and rebuilt. Blackthornes
Farmer, Equipment and Pets copy this file and change EMBLEM.
"""

import math
import os
import struct

SAMPLES = 4

# Which of the four emblems this addon wears in its portrait.
EMBLEM = "anvil"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Media", "Frame")


# -----------------------------------------------------------------------------
# Colour
# -----------------------------------------------------------------------------

def hexrgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


METAL_HI = hexrgb("#fbe6a6")
METAL = hexrgb("#c8a44d")
METAL_MID = hexrgb("#b08b3c")
METAL_LO = hexrgb("#5b4416")
EDGE = hexrgb("#050608")
GOLD = hexrgb("#E8C873")
GOLD_HI = hexrgb("#FFF4CF")


def mix(a, b, t):
    t = min(1.0, max(0.0, t))
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def ramp(stops, t):
    """A colour `t` of the way along [(position, colour), ...]."""
    t = min(1.0, max(0.0, t))
    for index in range(len(stops) - 1):
        p0, c0 = stops[index]
        p1, c1 = stops[index + 1]
        if t <= p1:
            return mix(c0, c1, (t - p0) / max(1e-6, p1 - p0))
    return stops[-1][1]


def over(top, bottom):
    """Paint (r, g, b, a) `top` over `bottom`."""
    if top is None:
        return bottom
    if bottom is None:
        return top
    ta, ba = top[3], bottom[3]
    a = ta + ba * (1 - ta)
    if a <= 0:
        return (0.0, 0.0, 0.0, 0.0)
    rgb = tuple((top[i] * ta + bottom[i] * ba * (1 - ta)) / a for i in range(3))
    return rgb + (a,)


# -----------------------------------------------------------------------------
# Geometry
# -----------------------------------------------------------------------------

def inside(polygon, x, y):
    result = False
    count = len(polygon)
    for i in range(count):
        ax, ay = polygon[i]
        bx, by = polygon[(i + 1) % count]
        if (ay > y) != (by > y):
            if x < ax + (y - ay) / (by - ay) * (bx - ax):
                result = not result
    return result


def edge_distance(polygon, x, y):
    best = 1e9
    count = len(polygon)
    for i in range(count):
        ax, ay = polygon[i]
        bx, by = polygon[(i + 1) % count]
        dx, dy = bx - ax, by - ay
        length = dx * dx + dy * dy
        t = 0.0 if length == 0 else max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / length))
        px, py = ax + t * dx, ay + t * dy
        best = min(best, math.hypot(x - px, y - py))
    return best


def rotated_rect(cx, cy, w, h, degrees):
    angle = math.radians(degrees)
    c, s = math.cos(angle), math.sin(angle)
    corners = [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)]
    return [(cx + x * c - y * s, cy + x * s + y * c) for x, y in corners]


def scaled(polygon, factor, dx=0.0, dy=0.0):
    return [(x * factor + dx, y * factor + dy) for x, y in polygon]


# -----------------------------------------------------------------------------
# Writing
# -----------------------------------------------------------------------------

def render(name, width, height, shade):
    """Supersample `shade(x, y)` -> (r, g, b, a) or None over the image."""
    pixels = []
    total = SAMPLES * SAMPLES

    # Bottom-up rows, the orientation a plain TGA declares.
    for row in range(height - 1, -1, -1):
        for column in range(width):
            r = g = b = a = 0.0
            for sy in range(SAMPLES):
                for sx in range(SAMPLES):
                    color = shade(column + (sx + 0.5) / SAMPLES, row + (sy + 0.5) / SAMPLES)
                    if color and color[3] > 0:
                        r += color[0] * color[3]
                        g += color[1] * color[3]
                        b += color[2] * color[3]
                        a += color[3]
            if a <= 0:
                pixels.append(b"\x00\x00\x00\x00")
                continue
            r, g, b = r / a, g / a, b / a
            pixels.append(bytes((
                int(round(min(1, b) * 255)), int(round(min(1, g) * 255)),
                int(round(min(1, r) * 255)), int(round(min(1, a / total) * 255)))))

    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, 32, 8)
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name + ".tga")
    with open(path, "wb") as handle:
        handle.write(header)
        handle.write(b"".join(pixels))
    print("wrote %s (%d bytes)" % (os.path.relpath(path, ROOT), os.path.getsize(path)))


# -----------------------------------------------------------------------------
# The pieces
# -----------------------------------------------------------------------------

def corner():
    """The top left corner: a metal bracket with a lit gem. The other three
    corners are this one turned by its texture coordinates."""
    k = 64 / 58.0
    bracket = scaled([(2, 2), (40, 2), (34, 8), (12, 8), (8, 12), (8, 34), (2, 40)], k)
    socket = scaled([(12, 12), (28, 12), (24, 16), (16, 16), (16, 24), (12, 28)], k)
    gem_c = 17.5 * k
    gem = [(gem_c, gem_c - 6.6 * k), (gem_c + 6.6 * k, gem_c), (gem_c, gem_c + 6.6 * k), (gem_c - 6.6 * k, gem_c)]

    def shade(x, y):
        color = None
        if inside(bracket, x, y):
            t = (x + y) / 80.0
            fill = ramp([(0, METAL_HI), (0.45, METAL_MID), (1, METAL_LO)], t)
            edge = edge_distance(bracket, x, y)
            color = (EDGE if edge < 1.2 else fill) + (1.0,)
        if inside(socket, x, y):
            edge = edge_distance(socket, x, y)
            color = ((METAL if edge < 1.1 else hexrgb("#0b0d12")) + (1.0,))
        # The gem, lit from its middle, with a soft light round it.
        d = abs(x - gem_c) + abs(y - gem_c)
        glow = max(0.0, 1 - d / (12 * k))
        if glow > 0:
            color = over(GOLD_HI + (0.55 * glow * glow,), color)
        if inside(gem, x, y):
            core = d / (6.6 * k)
            fill = ramp([(0, hexrgb("#fffbe8")), (0.35, hexrgb("#F6DE96")), (1, hexrgb("#8d6c27"))], core)
            color = ((EDGE if edge_distance(gem, x, y) < 0.9 else fill) + (1.0,))
        return color

    render("Corner", 64, 64, shade)


def portrait():
    """The round portrait: a metal ring with a dark well inside it, lit faintly
    gold at its rim. The emblem is drawn over it."""
    c = 64.0

    def shade(x, y):
        dx, dy = x - c, y - c
        r = math.hypot(dx, dy)
        if r > 63.5:
            return None
        if r > 62:
            return EDGE + (1.0,)
        if r > 54:
            # A ring of metal, its light turning round it like a turned bowl.
            angle = (math.degrees(math.atan2(dy, dx)) + 360 + 30) % 360 / 360.0
            fill = ramp([(0, METAL_HI), (0.2, METAL_LO), (0.4, hexrgb("#e3c26e")),
                         (0.6, hexrgb("#5b4416")), (0.8, METAL), (1, METAL_HI)], angle)
            # Rounded across the band: brighter in the middle of it.
            across = 1 - abs((r - 58) / 4.0)
            return mix(fill, (0, 0, 0), (1 - across) * 0.35) + (1.0,)
        if r > 52.5:
            return EDGE + (1.0,)
        # The well: lighter up top, near black at the bottom, gold at the rim.
        t = math.hypot(dx, dy + 14) / 66.0
        fill = ramp([(0, hexrgb("#2b3242")), (0.7, hexrgb("#0c0f15")), (1, hexrgb("#06070a"))], t)
        rim = max(0.0, (r - 40) / 12.5)
        return mix(fill, METAL, rim * rim * 0.28) + (1.0,)

    render("Portrait", 128, 128, shade)


def sweep():
    """The light that runs round the portrait ring: a bright arc fading out
    behind it. Drawn with ADD and turned by the window."""
    c = 64.0

    def shade(x, y):
        dx, dy = x - c, y - c
        r = math.hypot(dx, dy)
        band = 1 - abs((r - 58) / 5.5)
        if band <= 0:
            return None
        angle = (math.degrees(math.atan2(dy, dx)) + 360) % 360
        # Brightest at 90 degrees (the bottom of the ring, which the window
        # turns), trailing back over 70 degrees, sharp in front.
        if angle > 90 or angle < 20:
            return None
        tail = (angle - 20) / 70.0
        return GOLD_HI + (band * band * tail ** 2,)

    render("PortraitSweep", 128, 128, shade)


EMBLEMS = {
    # An anvil, horn to the left, with a hammer coming down on its face and
    # three sparks flying off the horn. Handle and head overlap so the hammer
    # reads as one piece at the 36 px the portrait shows it.
    "anvil": [
        [(4, 35), (14, 33.5), (56, 33.5), (56, 40), (46, 41.5), (40, 45.5), (40, 51),
         (47, 55), (48, 60.5), (16, 60.5), (17, 55), (24, 51), (24, 45.5), (19, 42.5),
         (12, 39)],
        rotated_rect(43.16, 16.83, 5, 27, -72),
        rotated_rect(26.99, 11.57, 15, 10, -72),
        [(11, 18.4), (14.6, 22), (11, 25.6), (7.4, 22)],
        [(8, 9.2), (10.8, 12), (8, 14.8), (5.2, 12)],
        [(17, 4.2), (19.8, 7), (17, 9.8), (14.2, 7)],
    ],
    "pick": [
        [(8, 24), (16, 15), (26, 11.5), (32, 11), (38, 11.5), (48, 15), (56, 24),
         (48, 21), (38, 19), (36, 23), (28, 23), (26, 19), (16, 21)],
        [(29, 21), (35, 21), (33.5, 58), (30.5, 58)],
    ],
    "shield": [
        [(32, 4), (54, 12), (54, 30), (50, 42), (42, 52), (32, 60), (22, 52), (14, 42), (10, 30), (10, 12)],
    ],
    "paw": [],
}
# The cut-outs drawn in the dark of the portrait over an emblem.
EMBLEM_HOLES = {
    "shield": [[(32, 17), (44, 31), (37, 31), (37, 46), (27, 46), (27, 31), (20, 31)]],
}
EMBLEM_BLOBS = {
    # (cx, cy, rx, ry, degrees)
    "paw": [(32, 42, 14, 12, 0), (16, 28, 6, 8, -20), (26, 17, 6, 8.5, 0),
            (38, 17, 6, 8.5, 0), (48, 28, 6, 8, 20)],
}


def emblem():
    """The addon's own sign in flat gold, as on its CurseForge logo, lit from
    above, with a soft gold light round it."""
    shapes = EMBLEMS[EMBLEM]
    holes = EMBLEM_HOLES.get(EMBLEM, [])
    blobs = EMBLEM_BLOBS.get(EMBLEM, [])

    def covered(x, y):
        if any(inside(hole, x, y) for hole in holes):
            return False
        if any(inside(shape, x, y) for shape in shapes):
            return True
        for cx, cy, rx, ry, degrees in blobs:
            a = math.radians(-degrees)
            px, py = x - cx, y - cy
            px, py = px * math.cos(a) - py * math.sin(a), px * math.sin(a) + py * math.cos(a)
            if (px / rx) ** 2 + (py / ry) ** 2 <= 1:
                return True
        return False

    def shade(x, y):
        if covered(x, y):
            return mix(GOLD_HI, GOLD, y / 40.0) + (1.0,)
        return None

    render("Emblem", 64, 64, shade)


def title_plate():
    """The plate the window's name sits on: a long hexagon, metal edged, dark
    inside. The window stretches its middle and keeps its ends."""
    outer = [(22, 4), (234, 4), (254, 32), (234, 60), (22, 60), (2, 32)]
    inner = [(23, 7), (233, 7), (250.5, 32), (233, 57), (23, 57), (5.5, 32)]

    def shade(x, y):
        if not inside(outer, x, y):
            return None
        if edge_distance(outer, x, y) < 1.0:
            return EDGE + (1.0,)
        if not inside(inner, x, y):
            return ramp([(0, hexrgb("#f6dc8e")), (0.5, METAL_MID), (1, METAL_LO)], (y - 4) / 56.0) + (1.0,)
        fill = mix(hexrgb("#1d2230"), hexrgb("#0b0d12"), (y - 7) / 50.0)
        if edge_distance(inner, x, y) < 1.0:
            return mix(fill, GOLD, 0.6) + (1.0,)
        return fill + (1.0,)

    render("TitlePlate", 256, 64, shade)


def close_gem():
    """The close button: a red gem in a metal ring with a pale cross on it."""
    c = 32.0
    cross = [rotated_rect(c, c, 22, 5, 45), rotated_rect(c, c, 22, 5, -45)]

    def shade(x, y):
        dx, dy = x - c, y - c
        r = math.hypot(dx, dy)
        if r > 31.5:
            return None
        if r > 30.3:
            return EDGE + (1.0,)
        if r > 25:
            angle = (math.degrees(math.atan2(dy, dx)) + 360 + 70) % 360 / 360.0
            return ramp([(0, METAL_HI), (0.25, METAL_LO), (0.5, hexrgb("#e3c26e")),
                         (0.75, METAL_LO), (1, METAL_HI)], angle) + (1.0,)
        if r > 23.8:
            return hexrgb("#2a0503") + (1.0,)
        t = math.hypot(dx, dy + 8) / 30.0
        fill = ramp([(0, hexrgb("#ff7a62")), (0.55, hexrgb("#b3261b")), (1, hexrgb("#4d0d08"))], t)
        # A glint on the top of the gem.
        shine = max(0.0, 1 - math.hypot(dx / 14.0, (dy + 13) / 6.0))
        fill = mix(fill, (1, 1, 1), shine * 0.45)
        if any(inside(bar, x, y) for bar in cross):
            return over(hexrgb("#fff1e8") + (1.0,), fill + (1.0,))
        return fill + (1.0,)

    render("CloseGem", 64, 64, shade)


def glow():
    """A soft white light, brightest in the middle. Stretched, tinted and
    added over the window: the rim glint, the portrait's light, a hover."""
    c = 32.0

    def shade(x, y):
        r = math.hypot(x - c, y - c) / 32.0
        if r >= 1:
            return None
        return (1.0, 1.0, 1.0, (1 - r) ** 2)

    render("Glow", 64, 64, shade)


def sort_arrow():
    """A small white triangle pointing down, tinted and flipped in game: a
    sorted list's order (Equipment's, the same in every addon)."""
    shape = [(2.0, 4.0), (14.0, 4.0), (8.0, 12.0)]

    def shade(x, y):
        return (1.0, 1.0, 1.0, 1.0) if inside(shape, x, y) else None

    render("SortArrow", 16, 16, shade)


def main():
    corner()
    portrait()
    sweep()
    emblem()
    title_plate()
    close_gem()
    glow()
    sort_arrow()


if __name__ == "__main__":
    main()
