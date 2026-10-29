"""Draw Media/Frame/MinimapBadge.tga, the face of the one minimap button that
every Blackthornes addon shares (UI/SharedMinimap.lua).

    python tools/make_minimap_art.py

A dark round face with the Blackthornes sign in gold: a B inside a ring of
thorns, as on the Discord server's icon. The game lays its round minimap
border over it. The same file in all five Blackthornes addons; rerun it,
never edit the TGA.
"""

import math

import make_frame_art as art

C = 32.0
FACE = 30.0


def thorn_shapes(ring, outer, inner, count):
    """The thorns round the ring: a long one every 1/count of a turn, a short
    one between, each leaning a little the same way."""
    shapes = []

    def point(radius, angle):
        return (C + radius * math.cos(angle), C + radius * math.sin(angle))

    for i in range(count):
        for angle, tip, width, lean in (
                (2 * math.pi * i / count - math.pi / 2, outer, 0.22, 0.10),
                (2 * math.pi * (i + 0.5) / count - math.pi / 2, inner, 0.14, 0.07)):
            shapes.append([point(ring - 1, angle - width), point(tip, angle + lean),
                           point(ring - 1, angle + width)])
    return shapes


def b_covered(x, y):
    """A bold B, 19 tall, its bowls round on the right."""
    top, mid, bottom = 22.5, 32.0, 41.5
    left, stem = 25.0, 29.5
    if not (top <= y <= bottom and left <= x <= 41.0):
        return False
    if x <= stem:
        return True

    def bowl(y0, y1, reach, thick):
        r = (y1 - y0) / 2.0
        cy = (y0 + y1) / 2.0
        straight = reach - r
        if y < y0 or y > y1:
            return False
        if x <= straight:
            outer = True
        else:
            outer = math.hypot(x - straight, y - cy) <= r
        if not outer:
            return False
        ir = r - thick
        if ir <= 0 or y < y0 + thick or y > y1 - thick:
            return True
        if x <= straight:
            return False
        return math.hypot(x - straight, y - cy) > ir

    return bowl(top, mid + 1.0, 39.5, 3.6) or bowl(mid - 1.0, bottom, 41.0, 3.8)


def thorn_covered(x, y):
    r = math.hypot(x - C, y - C)
    if 16.0 <= r <= 18.6:
        return True
    if any(art.inside(s, x, y) for s in THORNS):
        return True
    return b_covered(x, y)


THORNS = thorn_shapes(17.6, 29.0, 23.5, 8)


def badge(name, covered):
    def shade(x, y):
        dx, dy = x - C, y - C
        r = math.hypot(dx, dy)
        if r > FACE + 0.5:
            return None
        if covered(x, y):
            return art.mix(art.GOLD_HI, art.GOLD, (y - 10) / 40.0) + (1.0,)
        fill = art.mix(art.hexrgb("#1d2230"), art.hexrgb("#0b0d12"), y / 64.0)
        # A soft gold light behind the sign.
        glow = max(0.0, 1 - r / 26.0) ** 2 * 0.18
        return art.mix(fill, art.METAL, glow) + (1.0,)

    art.render(name, 64, 64, shade)


if __name__ == "__main__":
    badge("MinimapBadge", thorn_covered)
