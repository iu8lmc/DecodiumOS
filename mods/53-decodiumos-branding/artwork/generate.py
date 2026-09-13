#!/usr/bin/env python3
"""Generate the DecodiumOS artwork sources (SVG) from the Decodium 4 palette.

The SVG files next to this script are committed; the ISO build only renders
them with rsvg-convert. Re-run this script after changing the design:

    pip install fonttools
    python3 generate.py --font /path/to/Montserrat[wght].ttf

The wordmark text is converted to outlines, so rendering never depends on
the fonts installed in the image. Montserrat is licensed under the SIL OFL.
"""

import argparse
import math
import os
import random

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

HERE = os.path.dirname(os.path.abspath(__file__))

# Decodium 4 "Ocean Blue" (default dark) and "Stellar Light" palettes,
# from src/ui/DecodiumThemeManager.cpp in Decodium-4.0-Core-Shannon.
DARK = {
    "bg_deep": "#0A0F1A", "bg_medium": "#111827", "bg_light": "#1E2D42",
    "panel_header": "#283C57", "primary": "#4A90E2", "secondary": "#00D4FF",
    "accent": "#00FF88", "warning": "#FF8C00", "error": "#FF5F56",
    "text": "#E8F4FD", "text2": "#89B4D0",
}
LIGHT = {
    "bg_deep": "#EDF2F7", "bg_medium": "#E1E9F1", "bg_light": "#FFFFFF",
    "panel_header": "#EAF1F7", "primary": "#1F76D2", "secondary": "#0E9AAE",
    "accent": "#0E8C6A", "warning": "#B5741A", "error": "#CE4038",
    "text": "#0E1A22", "text2": "#5C6E7E",
}

# Signal trace of the logo, in a 512x512 box: flat carrier, then a decode
# burst with a tall central peak, like the Decodium 4 application icon.
LOGO_TRACE = [(66, 262), (148, 262), (174, 222), (200, 306), (232, 118),
              (268, 398), (300, 180), (328, 290), (354, 238), (378, 262),
              (446, 262)]
LOGO_PEAK = (232, 118)


def write(name, svg):
    path = os.path.join(HERE, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(svg.strip() + "\n")
    print("wrote", os.path.relpath(path, HERE))


def points(pts):
    return " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)


def logo_group(p=DARK, uid="l"):
    """The DecodiumOS symbol as an SVG group in a 512x512 coordinate box."""
    return f"""
  <defs>
    <linearGradient id="{uid}-bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{DARK['bg_light']}"/>
      <stop offset="0.55" stop-color="{DARK['bg_medium']}"/>
      <stop offset="1" stop-color="{DARK['bg_deep']}"/>
    </linearGradient>
    <filter id="{uid}-glow" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="9"/>
    </filter>
  </defs>
  <rect x="28" y="28" width="456" height="456" rx="112" fill="url(#{uid}-bg)"/>
  <rect x="28" y="28" width="456" height="456" rx="112" fill="none"
        stroke="{DARK['primary']}" stroke-width="22" opacity="0.45" filter="url(#{uid}-glow)"/>
  <rect x="28" y="28" width="456" height="456" rx="112" fill="none"
        stroke="{DARK['primary']}" stroke-width="10"/>
  <g fill="{DARK['secondary']}" opacity="0.45">
    <circle cx="112" cy="120" r="3"/><circle cx="392" cy="104" r="3"/>
    <circle cx="420" cy="170" r="2.5"/><circle cx="96" cy="388" r="2.5"/>
    <circle cx="360" cy="402" r="3"/><circle cx="170" cy="84" r="2"/>
  </g>
  <polyline points="{points(LOGO_TRACE)}" fill="none" stroke="{DARK['secondary']}"
            stroke-width="30" stroke-linejoin="round" stroke-linecap="round"
            opacity="0.55" filter="url(#{uid}-glow)"/>
  <polyline points="{points(LOGO_TRACE)}" fill="none" stroke="{DARK['secondary']}"
            stroke-width="20" stroke-linejoin="round" stroke-linecap="round"/>
  <circle cx="{LOGO_PEAK[0]}" cy="{LOGO_PEAK[1] - 6}" r="22" fill="{DARK['accent']}"
          opacity="0.6" filter="url(#{uid}-glow)"/>
  <circle cx="{LOGO_PEAK[0]}" cy="{LOGO_PEAK[1] - 6}" r="15" fill="{DARK['accent']}"/>
"""


def logo_svg():
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  <title>DecodiumOS</title>
{logo_group()}
</svg>"""


class Wordmark:
    """Outlines of the DECODIUM + OS wordmark from Montserrat."""

    def __init__(self, font_path, weight=650):
        font = TTFont(font_path)
        if "fvar" in font:
            font = instantiateVariableFont(font, {"wght": weight})
        self.font = font
        self.glyphs = font.getGlyphSet()
        self.cmap = font.getBestCmap()
        self.upem = font["head"].unitsPerEm
        self.cap = font["OS/2"].sCapHeight or 700

    def run(self, text, x, baseline, size, tracking=0.06):
        """Return (svg path data, advance) for text at the given size."""
        scale = size / self.upem
        pen = SVGPathPen(self.glyphs)
        cursor = 0.0
        for char in text:
            name = self.cmap[ord(char)]
            glyph = self.glyphs[name]
            transform = (scale, 0, 0, -scale, x + cursor, baseline)
            glyph.draw(TransformPen(pen, transform))
            cursor += glyph.width * scale + tracking * size
        return pen.getCommands(), cursor - tracking * size

    def cap_height(self, size):
        return self.cap * size / self.upem


def lockup_parts(mark, p=DARK, uid="lk"):
    """Horizontal logo + wordmark: (width, height, inner SVG markup)."""
    size = 120
    height = 200
    logo = 200
    gap = 36
    baseline = height / 2 + mark.cap_height(size) / 2
    word, advance_word = mark.run("DECODIUM", logo + gap, baseline, size)
    os_x = logo + gap + advance_word + 0.10 * size
    word_os, advance_os = mark.run("OS", os_x, baseline, size)
    width = math.ceil(os_x + advance_os + 8)
    inner = f"""
  <g transform="scale({logo / 512})">
{logo_group(uid=uid)}
  </g>
  <path d="{word}" fill="{p['text']}"/>
  <path d="{word_os}" fill="{p['secondary']}"/>"""
    return width, height, inner


def lockup_svg(mark):
    """Logo + wordmark for the GDM login logo and the Plymouth watermark."""
    width, height, inner = lockup_parts(mark)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">
  <title>DecodiumOS</title>
{inner}
</svg>"""


def smooth_path(pts):
    """Catmull-Rom spline through the points as a cubic Bezier path."""
    d = [f"M{pts[0][0]:.1f},{pts[0][1]:.1f}"]
    for i in range(len(pts) - 1):
        p0 = pts[i - 1] if i > 0 else pts[i]
        p1, p2 = pts[i], pts[i + 1]
        p3 = pts[i + 2] if i + 2 < len(pts) else p2
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d.append(f"C{c1[0]:.1f},{c1[1]:.1f} {c2[0]:.1f},{c2[1]:.1f} {p2[0]:.1f},{p2[1]:.1f}")
    return " ".join(d)


def signal(width, baseline, amplitude, seed, burst_at, burst_width, step=24):
    """A carrier with a Gaussian-enveloped decode burst, as spline points."""
    rng = random.Random(seed)
    pts = []
    for i in range(0, width // step + 2):
        x = i * step
        env = math.exp(-((x - burst_at) / burst_width) ** 2)
        carrier = 0.12 * math.sin(x / 140.0 + seed)
        wobble = 0.08 * math.sin(x / 57.0 + seed * 1.7)
        burst = env * (math.sin(x / 19.0 + seed) * 0.7 + rng.uniform(-0.45, 0.45))
        pts.append((x, baseline + amplitude * (carrier + wobble + burst)))
    return smooth_path(pts)


def wallpaper_svg(p, dark):
    w, h = 3840, 2160
    grid = []
    for x in range(0, w + 1, 160):
        grid.append(f'<line x1="{x}" y1="0" x2="{x}" y2="{h}"/>')
    for y in range(0, h + 1, 160):
        grid.append(f'<line x1="0" y1="{y}" x2="{w}" y2="{y}"/>')
    # Faint waterfall streaks in the lower third, like a decoder display.
    rng = random.Random(7)
    streaks = []
    for _ in range(140):
        x = rng.uniform(0, w)
        top = rng.uniform(h * 0.62, h * 0.9)
        length = rng.uniform(60, 420)
        opacity = rng.uniform(0.04, 0.16) if dark else rng.uniform(0.05, 0.14)
        color = rng.choice([p["secondary"], p["primary"], p["accent"]])
        streaks.append(
            f'<rect x="{x:.0f}" y="{top:.0f}" width="{rng.uniform(4, 14):.0f}" '
            f'height="{length:.0f}" rx="3" fill="{color}" opacity="{opacity:.2f}"/>')
    main = signal(w, h * 0.52, 260, 3, w * 0.62, 520)
    second = signal(w, h * 0.56, 170, 11, w * 0.34, 700)
    third = signal(w, h * 0.49, 120, 5, w * 0.8, 380)
    glow_opacity = 0.55 if dark else 0.25
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">
  <title>DecodiumOS {'dark' if dark else 'light'}</title>
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{p['bg_deep']}"/>
      <stop offset="0.55" stop-color="{p['bg_medium']}"/>
      <stop offset="1" stop-color="{p['bg_deep']}"/>
    </linearGradient>
    <radialGradient id="halo" cx="0.62" cy="0.5" r="0.55">
      <stop offset="0" stop-color="{p['primary']}" stop-opacity="{0.30 if dark else 0.18}"/>
      <stop offset="1" stop-color="{p['primary']}" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="halo2" cx="0.2" cy="0.15" r="0.5">
      <stop offset="0" stop-color="{p['secondary']}" stop-opacity="{0.14 if dark else 0.10}"/>
      <stop offset="1" stop-color="{p['secondary']}" stop-opacity="0"/>
    </radialGradient>
    <filter id="glow" x="-5%" y="-50%" width="110%" height="200%">
      <feGaussianBlur stdDeviation="18"/>
    </filter>
  </defs>
  <rect width="{w}" height="{h}" fill="url(#bg)"/>
  <rect width="{w}" height="{h}" fill="url(#halo)"/>
  <rect width="{w}" height="{h}" fill="url(#halo2)"/>
  <g stroke="{p['primary']}" stroke-width="2" opacity="{0.07 if dark else 0.10}">
    {''.join(grid)}
  </g>
  <g>{''.join(streaks)}</g>
  <path d="{second}" fill="none" stroke="{p['primary']}" stroke-width="6" opacity="0.55"/>
  <path d="{third}" fill="none" stroke="{p['accent']}" stroke-width="4" opacity="0.45"/>
  <path d="{main}" fill="none" stroke="{p['secondary']}" stroke-width="26"
        opacity="{glow_opacity}" filter="url(#glow)"/>
  <path d="{main}" fill="none" stroke="{p['secondary']}" stroke-width="9"
        stroke-linejoin="round"/>
</svg>"""


def throbber_svg():
    """Plymouth spinner; the build rotates @ANGLE@ to render the frames."""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
  <circle cx="32" cy="32" r="24" fill="none" stroke="{DARK['primary']}" stroke-width="5" opacity="0.28"/>
  <g transform="rotate(@ANGLE@ 32 32)">
    <path d="M32 8 A24 24 0 0 1 56 32" fill="none" stroke="{DARK['secondary']}"
          stroke-width="5" stroke-linecap="round"/>
    <circle cx="56" cy="32" r="3.5" fill="{DARK['accent']}"/>
  </g>
</svg>"""


def slide_frame(body, p=DARK):
    w, h = 752, 376
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">
  <defs>
    <linearGradient id="sbg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{p['bg_light']}"/>
      <stop offset="0.6" stop-color="{p['bg_medium']}"/>
      <stop offset="1" stop-color="{p['bg_deep']}"/>
    </linearGradient>
    <filter id="sglow" x="-10%" y="-50%" width="120%" height="200%">
      <feGaussianBlur stdDeviation="6"/>
    </filter>
  </defs>
  <rect width="{w}" height="{h}" fill="url(#sbg)"/>
  <g stroke="{p['primary']}" stroke-width="1" opacity="0.10">
    {''.join(f'<line x1="{x}" y1="0" x2="{x}" y2="{h}"/>' for x in range(0, w, 47))}
    {''.join(f'<line x1="0" y1="{y}" x2="{w}" y2="{y}"/>' for y in range(0, h, 47))}
  </g>
{body}
</svg>"""


MONO = "'Cascadia Code', 'Noto Sans Mono', 'DejaVu Sans Mono', monospace"
SANS = "'Noto Sans', 'Cantarell', 'DejaVu Sans', sans-serif"


def slide_welcome(mark):
    width, height, inner = lockup_parts(mark, uid="sw")
    trace = signal(752, 300, 40, 2, 500, 90, step=12)
    return slide_frame(f"""
  <svg x="96" y="96" width="560" height="120" viewBox="0 0 {width} {height}"
       preserveAspectRatio="xMidYMid meet">
{inner}
  </svg>
  <path d="{trace}" fill="none" stroke="{DARK['secondary']}" stroke-width="10" opacity="0.4" filter="url(#sglow)"/>
  <path d="{trace}" fill="none" stroke="{DARK['secondary']}" stroke-width="3"/>""")


def slide_waterfall():
    rng = random.Random(4)
    cells = []
    for col in range(0, 752, 16):
        for row in range(0, 376, 16):
            v = rng.random() ** 3 * 0.35
            cells.append(f'<rect x="{col}" y="{row}" width="16" height="16" '
                         f'fill="{DARK["primary"]}" opacity="{v:.2f}"/>')
    signals = []
    for x, top, length, color in [(120, 40, 220, "secondary"), (206, 100, 200, "accent"),
                                  (318, 20, 300, "secondary"), (430, 140, 160, "warning"),
                                  (520, 60, 250, "accent"), (640, 90, 190, "secondary")]:
        signals.append(f'<rect x="{x}" y="{top}" width="14" height="{length}" rx="4" '
                       f'fill="{DARK[color]}" opacity="0.9"/>')
        signals.append(f'<rect x="{x - 6}" y="{top}" width="26" height="{length}" rx="8" '
                       f'fill="{DARK[color]}" opacity="0.35" filter="url(#sglow)"/>')
    return slide_frame(f"""
  <g>{''.join(cells)}</g>
  {''.join(signals)}
  <rect x="0" y="326" width="752" height="50" fill="{DARK['bg_deep']}" opacity="0.85"/>
  <text x="24" y="358" font-family="{MONO}" font-size="20" fill="{DARK['accent']}">FT2  +12  0.2  1850 ~  CQ IU8LMC JN70</text>""")


def slide_digital():
    lines = [("0 1  1234 ~  CQ DX K1ABC FN42", "accent"),
             ("-5 0.3  987 ~  IU8LMC K1ABC R-05", "secondary"),
             ("+3 0.1 1500 ~  CQ POTA EA3XYZ JN11", "text"),
             ("-12 0.4 2210 ~  JA1XYZ IU8LMC -12", "secondary"),
             ("RTTY  PSK31  OLIVIA  MFSK  JS8", "text2")]
    rows = []
    for i, (text, color) in enumerate(lines):
        rows.append(f'<text x="56" y="{92 + i * 52}" font-family="{MONO}" font-size="24" '
                    f'fill="{DARK[color]}">{text}</text>')
    return slide_frame(f"""
  <rect x="28" y="40" width="696" height="296" rx="18" fill="{DARK['bg_deep']}" opacity="0.8"
        stroke="{DARK['primary']}" stroke-opacity="0.6" stroke-width="2"/>
  {''.join(rows)}""")


def slide_radio():
    return slide_frame(f"""
  <rect x="96" y="92" width="560" height="200" rx="26" fill="{DARK['bg_deep']}"
        stroke="{DARK['primary']}" stroke-width="3"/>
  <rect x="136" y="126" width="300" height="84" rx="10" fill="#07131F" stroke="{DARK['secondary']}" stroke-opacity="0.7"/>
  <text x="152" y="186" font-family="{MONO}" font-size="44" fill="{DARK['secondary']}">14.074.00</text>
  <text x="152" y="246" font-family="{SANS}" font-size="20" fill="{DARK['text2']}">USB-D  CAT  PTT</text>
  <circle cx="550" cy="190" r="62" fill="{DARK['bg_light']}" stroke="{DARK['primary']}" stroke-width="4"/>
  <circle cx="550" cy="190" r="40" fill="{DARK['bg_medium']}" stroke="{DARK['secondary']}" stroke-opacity="0.6" stroke-width="2"/>
  <circle cx="574" cy="170" r="6" fill="{DARK['accent']}"/>
  <circle cx="460" cy="130" r="7" fill="{DARK['accent']}"/>
  <circle cx="460" cy="160" r="7" fill="{DARK['error']}"/>""")


def slide_sdr():
    trace = signal(752, 240, 110, 9, 380, 60, step=8)
    return slide_frame(f"""
  <ellipse cx="376" cy="140" rx="300" ry="84" fill="none" stroke="{DARK['primary']}"
           stroke-width="2" stroke-dasharray="10 8" opacity="0.7"/>
  <circle cx="620" cy="95" r="12" fill="{DARK['accent']}"/>
  <circle cx="620" cy="95" r="24" fill="{DARK['accent']}" opacity="0.3" filter="url(#sglow)"/>
  <path d="{trace}" fill="none" stroke="{DARK['secondary']}" stroke-width="12" opacity="0.4" filter="url(#sglow)"/>
  <path d="{trace}" fill="none" stroke="{DARK['secondary']}" stroke-width="3"/>""")


def slide_terminal():
    lines = [("$ sudo decodiumos-update-decodium", "accent"),
             ("Decodium installed: 1.0.628; latest: 1.0.628", "text2"),
             ("$ rigctl -m 3073 -r /dev/ttyUSB0 f", "accent"),
             ("14074000", "secondary"),
             ("GPL-3.0  ·  AnduinOS 2  ·  Ubuntu 26.04", "text2")]
    rows = []
    for i, (text, color) in enumerate(lines):
        rows.append(f'<text x="60" y="{128 + i * 44}" font-family="{MONO}" font-size="21" '
                    f'fill="{DARK[color]}">{text}</text>')
    return slide_frame(f"""
  <rect x="32" y="48" width="688" height="290" rx="14" fill="#060A12" opacity="0.92"
        stroke="{DARK['primary']}" stroke-opacity="0.6" stroke-width="2"/>
  <circle cx="60" cy="74" r="7" fill="{DARK['error']}"/>
  <circle cx="84" cy="74" r="7" fill="{DARK['warning']}"/>
  <circle cx="108" cy="74" r="7" fill="{DARK['accent']}"/>
  {''.join(rows)}""")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--font", required=True, help="Montserrat (variable or SemiBold) TTF")
    args = parser.parse_args()
    mark = Wordmark(args.font)
    write("logo.svg", logo_svg())
    write("lockup.svg", lockup_svg(mark))
    write("wallpaper-dark.svg", wallpaper_svg(DARK, True))
    write("wallpaper-light.svg", wallpaper_svg(LIGHT, False))
    write("throbber.svg", throbber_svg())
    write("slides/welcome.svg", slide_welcome(mark))
    write("slides/jb.svg", slide_waterfall())
    write("slides/st.svg", slide_digital())
    write("slides/gaming.svg", slide_radio())
    write("slides/pv.svg", slide_sdr())
    write("slides/sc.svg", slide_terminal())


if __name__ == "__main__":
    main()
