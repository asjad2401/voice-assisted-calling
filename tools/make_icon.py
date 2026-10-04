"""Generates the Life Lense launcher icon.

Writes Android adaptive-icon vector layers (background, foreground,
monochrome) plus legacy PNGs and a 512px store icon, all from the same
geometry. Run from the repo root:  python3 tools/make_icon.py
"""
import math
import os

from PIL import Image, ImageDraw

RES = "android/app/src/main/res"

# Adaptive icon canvas is 108x108dp; launchers mask it and only the centre
# 66dp circle is guaranteed visible, so everything stays within r=33.
C = 54.0
BG_TOP, BG_BOTTOM = "#14336B", "#081530"
AMBER_LIGHT, AMBER = "#FFD95A", "#FFB300"
NAVY = "#0A1A3A"
WHITE = "#FFFFFF"

EYE_L, EYE_R, EYE_CTRL = 22.0, 86.0, 21.0  # almond: corners and bezier control offset
EYE_STROKE = 5.0
IRIS_R = 15.0
PUPIL_R = 7.0
BLADE_STROKE = 0.9
GLINT = (48.0, 47.0, 2.6)
FACET_LIGHT, FACET_DARK = "#FFD54F", "#FFA000"


def hexagon(r, rot=30):
    return [(C + r * math.cos(math.radians(rot + 60 * i)),
             C + r * math.sin(math.radians(rot + 60 * i))) for i in range(6)]


def aperture_blades():
    """Lines continuing each pupil edge outward until they meet the iris rim."""
    pts = hexagon(PUPIL_R)
    lines = []
    for i in range(6):
        (x0, y0), (x1, y1) = pts[i], pts[(i + 1) % 6]
        dx, dy = x0 - x1, y0 - y1
        n = math.hypot(dx, dy)
        dx, dy = dx / n, dy / n
        # Solve |p0 + t*d - C| = IRIS_R for t > 0.
        fx, fy = x0 - C, y0 - C
        b = fx * dx + fy * dy
        t = -b + math.sqrt(b * b - (fx * fx + fy * fy - IRIS_R * IRIS_R))
        lines.append(((x0, y0), (x0 + t * dx, y0 + t * dy)))
    return lines


def facets(steps=12):
    """The six aperture blades: each is bounded by two blade lines, the rim
    arc between their ends, and one pupil edge."""
    pts = hexagon(PUPIL_R)
    lines = aperture_blades()
    out = []
    for i in range(6):
        j = (i + 1) % 6
        e_i, e_j = lines[i][1], lines[j][1]
        a0 = math.atan2(e_j[1] - C, e_j[0] - C)
        a1 = math.atan2(e_i[1] - C, e_i[0] - C)
        da = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
        arc = [(C + IRIS_R * math.cos(a0 + da * k / steps), C + IRIS_R * math.sin(a0 + da * k / steps))
               for k in range(steps + 1)]
        out.append([pts[j]] + arc + [pts[i]])
    return out


def poly_path(pts):
    return "M" + " L".join(f"{fmt(x)},{fmt(y)}" for x, y in pts) + " Z"


def eye_path():
    top, bot = C - EYE_CTRL * 1.5, C + EYE_CTRL * 1.5
    return (f"M{EYE_L},{C} Q{C},{top} {EYE_R},{C} Q{C},{bot} {EYE_L},{C} Z")


def quad(p0, p1, p2, steps=60):
    return [((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0],
             (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1])
            for t in (i / steps for i in range(steps + 1))]


def eye_polygon():
    top, bot = C - EYE_CTRL * 1.5, C + EYE_CTRL * 1.5
    return quad((EYE_L, C), (C, top), (EYE_R, C)) + quad((EYE_R, C), (C, bot), (EYE_L, C))[1:]


def circle_path(cx, cy, r):
    return (f"M{cx - r},{cy} a{r},{r} 0 1,0 {2 * r},0 a{r},{r} 0 1,0 {-2 * r},0 Z")


def fmt(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


# ---- vector drawables --------------------------------------------------------

VECTOR_HEAD = ('<?xml version="1.0" encoding="utf-8"?>\n'
               '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
               '    xmlns:aapt="http://schemas.android.com/aapt"\n'
               '    android:width="108dp" android:height="108dp"\n'
               '    android:viewportWidth="108" android:viewportHeight="108">\n')


def gradient(start, end, c0, c1):
    return (f'        <aapt:attr name="android:fillColor">\n'
            f'            <gradient android:type="linear"\n'
            f'                android:startX="{fmt(start[0])}" android:startY="{fmt(start[1])}"\n'
            f'                android:endX="{fmt(end[0])}" android:endY="{fmt(end[1])}"\n'
            f'                android:startColor="{c0}" android:endColor="{c1}" />\n'
            f'        </aapt:attr>\n')


def blades_path():
    return " ".join(f"M{fmt(a[0])},{fmt(a[1])} L{fmt(b[0])},{fmt(b[1])}" for a, b in aperture_blades())


def pupil_path():
    pts = hexagon(PUPIL_R)
    return "M" + " L".join(f"{fmt(x)},{fmt(y)}" for x, y in pts) + " Z"


def foreground_xml(mono=False):
    eye_color = WHITE if mono else AMBER
    out = [VECTOR_HEAD]
    # Eye outline
    out.append(f'    <path android:pathData="{eye_path()}"\n'
               f'        android:strokeColor="{eye_color}" android:strokeWidth="{EYE_STROKE}"\n'
               f'        android:strokeLineJoin="round" android:fillColor="#00000000" />\n')
    # Monochrome layers are alpha masks (the system supplies the colour), so a
    # dark aperture on a solid iris would vanish. Draw the lens as outlines.
    if mono:
        out.append(f'    <path android:pathData="{circle_path(C, C, IRIS_R - 1.5)}"\n'
                   f'        android:strokeColor="{WHITE}" android:strokeWidth="3" android:fillColor="#00000000" />\n')
        line = WHITE
    else:
        for i, f in enumerate(facets()):
            shade = FACET_LIGHT if i % 2 == 0 else FACET_DARK
            out.append(f'    <path android:pathData="{poly_path(f)}" android:fillColor="{shade}"\n'
                       f'        android:strokeColor="{shade}" android:strokeWidth="0.3" />\n')
        line = NAVY
    # Aperture: hexagonal pupil plus blade edges
    out.append(f'    <path android:pathData="{pupil_path()}" android:fillColor="{line}" />\n')
    out.append(f'    <path android:pathData="{blades_path()}"\n'
               f'        android:strokeColor="{line}" android:strokeWidth="{BLADE_STROKE}"\n'
               f'        android:strokeLineCap="round" />\n')
    if not mono:
        gx, gy, gr = GLINT
        out.append(f'    <path android:pathData="{circle_path(gx, gy, gr)}" android:fillColor="{WHITE}" />\n')
    out.append('</vector>\n')
    return "".join(out)


def background_xml():
    return (VECTOR_HEAD
            + '    <path android:pathData="M0,0 H108 V108 H0 Z">\n'
            + gradient((0, 0), (0, 108), BG_TOP, BG_BOTTOM)
            + '    </path>\n</vector>\n')


ADAPTIVE_XML = ('<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@drawable/ic_launcher_background" />\n'
                '    <foreground android:drawable="@drawable/ic_launcher_foreground" />\n'
                '    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />\n'
                '</adaptive-icon>\n')


# ---- raster ------------------------------------------------------------------

def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def lerp(c0, c1, t):
    return tuple(round(a + (b - a) * t) for a, b in zip(c0, c1))


def render(size, shape="circle"):
    """Renders the full icon (background + foreground) at [size] px."""
    ss = 4
    S = size * ss
    k = S / 108.0
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    bg = Image.new("RGBA", (S, S))
    top, bot = hex_rgb(BG_TOP), hex_rgb(BG_BOTTOM)
    bd = ImageDraw.Draw(bg)
    for y in range(S):
        bd.line([(0, y), (S, y)], fill=lerp(top, bot, y / S) + (255,))
    mask = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(mask)
    if shape == "circle":
        md.ellipse([0, 0, S - 1, S - 1], fill=255)
    else:
        md.rounded_rectangle([0, 0, S - 1, S - 1], radius=S * 0.22, fill=255)
    img.paste(bg, (0, 0), mask)

    # Legacy icons have no launcher mask, so zoom the 66dp safe zone up a bit.
    zoom = 1.25
    def P(x, y):
        return ((C + (x - C) * zoom) * k, (C + (y - C) * zoom) * k)
    def R(r):
        return r * zoom * k

    d = ImageDraw.Draw(img)
    eye = [P(x, y) for x, y in eye_polygon()]
    d.line(eye + [eye[0]], fill=hex_rgb(AMBER) + (255,), width=round(R(EYE_STROKE)), joint="curve")
    for x, y in (eye[0], eye[len(eye) // 2]):
        r = R(EYE_STROKE) / 2
        d.ellipse([x - r, y - r, x + r, y + r], fill=hex_rgb(AMBER) + (255,))

    for i, f in enumerate(facets()):
        shade = FACET_LIGHT if i % 2 == 0 else FACET_DARK
        d.polygon([P(x, y) for x, y in f], fill=hex_rgb(shade) + (255,))
    d.polygon([P(x, y) for x, y in hexagon(PUPIL_R)], fill=hex_rgb(NAVY) + (255,))
    for a, b in aperture_blades():
        d.line([P(*a), P(*b)], fill=hex_rgb(NAVY) + (255,), width=round(R(BLADE_STROKE)))
    gx, gy = P(GLINT[0], GLINT[1])
    gr = R(GLINT[2])
    d.ellipse([gx - gr, gy - gr, gx + gr, gy + gr], fill=(255, 255, 255, 255))

    return img.resize((size, size), Image.LANCZOS)


def main():
    os.makedirs(f"{RES}/drawable", exist_ok=True)
    os.makedirs(f"{RES}/mipmap-anydpi-v26", exist_ok=True)
    with open(f"{RES}/drawable/ic_launcher_background.xml", "w") as f:
        f.write(background_xml())
    with open(f"{RES}/drawable/ic_launcher_foreground.xml", "w") as f:
        f.write(foreground_xml())
    with open(f"{RES}/drawable/ic_launcher_monochrome.xml", "w") as f:
        f.write(foreground_xml(mono=True))
    for name in ("ic_launcher", "ic_launcher_round"):
        with open(f"{RES}/mipmap-anydpi-v26/{name}.xml", "w") as f:
            f.write(ADAPTIVE_XML)

    for density, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        render(px, "rounded").save(f"{RES}/mipmap-{density}/ic_launcher.png")
        render(px, "circle").save(f"{RES}/mipmap-{density}/ic_launcher_round.png")
    os.makedirs("branding", exist_ok=True)
    render(512, "rounded").save("branding/life_lense_icon_512.png")


if __name__ == "__main__":
    main()
