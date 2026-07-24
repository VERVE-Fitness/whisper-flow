"""Generate the Whisper Flow app icon SVG from anatomical key points.

This file is the SOURCE OF RECORD for the icon geometry: Resources/AppIcon.svg
and Resources/AppIcon.icns are both generated artefacts. To change the icon,
nudge the points below and re-run scripts/make-icon.sh -- never hand-edit the
SVG (it gets overwritten) or the binary .icns.

The head silhouette is a closed Catmull-Rom spline through the points below,
so the curve stays smooth and organic no matter how the points are nudged.
Hand-picking bezier control points instead produced angular wedges at the
nose and a visible kink at the crown, which is why the spline exists.
"""
import math
import sys

# Head profile, clockwise from the crown, in a 240x216 design space.
# Facing right: crown -> forehead -> brow -> nose -> lips -> chin -> jaw ->
# nape -> back of skull -> crown.
HEAD = [
    (100, 16),   # crown
    (132, 26),   # upper forehead
    (148, 50),   # forehead
    (154, 72),   # brow ridge
    (149, 82),   # nasion dip
    (155, 97),   # nose bridge
    (168, 114),  # nose tip
    (154, 122),  # under nose
    (148, 133),  # upper lip
    (152, 141),  # mouth
    (146, 152),  # chin crease
    (154, 162),  # chin
    (144, 175),  # under chin
    (124, 183),  # jaw
    (102, 185),  # jaw angle
    (83, 179),   # nape
    (70, 165),   # jaw/skull junction
    (62, 145),   # lower back of skull
    (58, 122),   # back of skull, widest
    (59, 98),    # back of skull
    (66, 72),    # back of skull, upper
    (78, 44),    # upper back
]

MOUTH = (152, 139)      # sound waves radiate from here
WAVE_RADII = (40, 58, 76)
WAVE_HALF_ANGLE = 47.0  # degrees either side of horizontal
STROKE = 6.2

PLATE = dict(inset=100, size=824, radius=185)  # Apple macOS icon template
CANVAS = 1024
CONTENT = 700           # mark fits inside this box, centred on the canvas


def catmull_rom_closed(pts, tension=1.0):
    """Closed Catmull-Rom spline as SVG cubic bezier path data."""
    n = len(pts)
    d = [f"M {pts[0][0]:.2f} {pts[0][1]:.2f}"]
    for i in range(n):
        p0 = pts[(i - 1) % n]
        p1 = pts[i]
        p2 = pts[(i + 1) % n]
        p3 = pts[(i + 2) % n]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6.0 * tension,
              p1[1] + (p2[1] - p0[1]) / 6.0 * tension)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6.0 * tension,
              p2[1] - (p3[1] - p1[1]) / 6.0 * tension)
        d.append(f"C {c1[0]:.2f} {c1[1]:.2f} {c2[0]:.2f} {c2[1]:.2f} "
                 f"{p2[0]:.2f} {p2[1]:.2f}")
    d.append("Z")
    return " ".join(d)


def arc(cx, cy, r, half_angle):
    th = math.radians(half_angle)
    x = cx + r * math.cos(th)
    dy = r * math.sin(th)
    return (f"M {x:.2f} {cy - dy:.2f} A {r} {r} 0 0 1 {x:.2f} {cy + dy:.2f}")


def bbox():
    xs = [p[0] for p in HEAD]
    ys = [p[1] for p in HEAD]
    # Waves extend the box to the right and vertically.
    r = max(WAVE_RADII)
    th = math.radians(WAVE_HALF_ANGLE)
    xs.append(MOUTH[0] + r)
    ys += [MOUTH[1] - r * math.sin(th), MOUTH[1] + r * math.sin(th)]
    pad = STROKE / 2
    return min(xs) - pad, min(ys) - pad, max(xs) + pad, max(ys) + pad


def build():
    x0, y0, x1, y1 = bbox()
    w, h = x1 - x0, y1 - y0
    scale = CONTENT / max(w, h)
    tx = CANVAS / 2 - (x0 + w / 2) * scale
    ty = CANVAS / 2 - (y0 + h / 2) * scale

    waves = "\n".join(
        f'    <path d="{arc(MOUTH[0], MOUTH[1], r, WAVE_HALF_ANGLE)}"/>'
        for r in WAVE_RADII)

    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {CANVAS} {CANVAS}" width="{CANVAS}" height="{CANVAS}">
  <!-- Whisper Flow app icon: speaking head in profile with sound waves.
       Vector source of record for Resources/AppIcon.icns. Regenerate the
       .icns with scripts/make-icon.sh after editing this file, never by
       hand-editing the binary .icns.

       Layout follows Apple's macOS icon template: the rounded-square plate
       is {PLATE['size']}x{PLATE['size']} inset in a {CANVAS}x{CANVAS} canvas (corner radius {PLATE['radius']}),
       with the mark inset further so it never crowds the corners at small
       sizes. The head outline is a closed Catmull-Rom spline through
       anatomical key points (crown, brow, nose tip, chin, jaw, nape), so
       the silhouette stays smooth; see scripts/gen-icon.py. -->
  <rect x="{PLATE['inset']}" y="{PLATE['inset']}" width="{PLATE['size']}" height="{PLATE['size']}" rx="{PLATE['radius']}" fill="#ffffff"/>

  <g transform="translate({tx:.2f}, {ty:.2f}) scale({scale:.4f})"
     fill="none" stroke="#1a1a1a" stroke-width="{STROKE}"
     stroke-linecap="round" stroke-linejoin="round">
    <path d="{catmull_rom_closed(HEAD)}"/>
{waves}
  </g>
</svg>
'''


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.svg"
    with open(out, "w") as f:
        f.write(build())
    print("wrote", out)
