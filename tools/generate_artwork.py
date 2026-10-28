#!/usr/bin/env python3
"""Draws the security key and tutorial artwork as SVG files in the asset catalog.

The drawings are the app's own and use the colors of the app icon. Run from the repository root:

    python3 tools/generate_artwork.py
"""

import json
import math
import random
import re
from pathlib import Path

ASSETS = Path(__file__).resolve().parent.parent / "Authenticator" / "Assets.xcassets"

LIGHT = {
    "frame": "#8E8E93", "screen": "#F2F2F7", "island": "#3A3A3C",
    "body": "#B2001F", "pad": "#F7C6CE", "print": "#B2001F",
    "metal": "#C7C7CC", "metal_dark": "#8E8E93",
    "arrow": "#8E8E93", "accent": "#B2001F", "ink": "#1C1C1E",
    "card": "#FFFFFF", "card_stroke": "#C7C7CC", "bar": "#D1D1D6", "code": "#3A3A3C",
    "avatars": ["#F9C1E0", "#FFC3C2", "#EACFB6"],
}

DARK = {
    "frame": "#636366", "screen": "#2C2C2E", "island": "#000000",
    "body": "#C8102E", "pad": "#FFBFCB", "print": "#C8102E",
    "metal": "#AEAEB2", "metal_dark": "#636366",
    "arrow": "#8E8E93", "accent": "#FFBFCB", "ink": "#F2F2F7",
    "card": "#1C1C1E", "card_stroke": "#48484A", "bar": "#48484A", "code": "#E5E5EA",
    "avatars": ["#75375C", "#7D3638", "#67492B"],
}


def svg(width, height, body):
    return (f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
            f'viewBox="0 0 {width} {height}">\n{body}</svg>\n')


def rect(x, y, w, h, r, fill):
    return f'<rect x="{x:g}" y="{y:g}" width="{w:g}" height="{h:g}" rx="{r:g}" fill="{fill}"/>\n'


def circle(cx, cy, r, fill):
    return f'<circle cx="{cx:g}" cy="{cy:g}" r="{r:g}" fill="{fill}"/>\n'


def arc(cx, cy, r, start, end, color, width):
    """A stroked arc from `start` to `end` degrees, clockwise with 0 pointing right."""
    a0, a1 = math.radians(start), math.radians(end)
    x0, y0 = cx + r * math.cos(a0), cy + r * math.sin(a0)
    x1, y1 = cx + r * math.cos(a1), cy + r * math.sin(a1)
    large = 1 if (end - start) % 360 > 180 else 0
    return (f'<path d="M{x0:.2f},{y0:.2f} A{r:g},{r:g} 0 {large} 1 {x1:.2f},{y1:.2f}" fill="none" '
            f'stroke="{color}" stroke-width="{width:g}" stroke-linecap="round"/>\n')


def group(transform, body):
    return f'<g transform="{transform}">\n{body}</g>\n'


# Security keys, drawn upright with the connector at the bottom and centered on x = 0, y = 0 at the top.

def usb_a(top, p):
    return rect(-60, top, 120, 150, 8, p["metal"]) + rect(-36, top + 70, 24, 20, 3, p["metal_dark"]) + \
        rect(12, top + 70, 24, 20, 3, p["metal_dark"])


def usb_c(top, p):
    return rect(-42, top, 84, 110, 22, p["metal"]) + rect(-24, top + 30, 48, 62, 12, p["metal_dark"])


def lightning(bottom, p):
    return rect(-30, bottom - 100, 60, 100, 26, p["metal"]) + \
        "".join(rect(-14, bottom - 82 + i * 22, 28, 10, 5, p["metal_dark"]) for i in range(3))


def touch_pad(cy, size, p):
    return rect(-size / 2, cy - size / 2, size, size, size * 0.3, p["pad"]) + \
        rect(-size * 0.3, cy - size * 0.3, size * 0.6, size * 0.6, size * 0.18, p["body"]) + \
        rect(-size * 0.22, cy - size * 0.22, size * 0.44, size * 0.44, size * 0.12, p["pad"])


def fingerprint_pad(cy, size, p):
    out = rect(-size / 2, cy - size / 2, size, size, size * 0.3, p["pad"])
    for i, r in enumerate((size * 0.1, size * 0.2, size * 0.3, size * 0.38)):
        start, end = (200 - i * 10, 340 + i * 10) if i < 3 else (205, 335)
        out += arc(0, cy + size * 0.06, r, start, end, p["print"], size * 0.055)
        if i < 3:
            out += arc(0, cy + size * 0.06, r, 10 + i * 8, 170 - i * 8, p["print"], size * 0.055)
    return out


def key(kind, p):
    """Returns the drawing and its height."""
    if kind == "usba":
        return usb_a(244, p) + rect(-90, 0, 180, 250, 36, p["body"]) + touch_pad(140, 84, p), 394
    if kind == "usbc":
        return usb_c(244, p) + rect(-85, 0, 170, 250, 36, p["body"]) + touch_pad(140, 84, p), 354
    if kind == "usbc-lightning":
        return lightning(106, p) + usb_c(300, p) + rect(-75, 100, 150, 206, 32, p["body"]) + \
            touch_pad(203, 76, p), 410
    if kind == "bio-usbc":
        return usb_c(244, p) + rect(-115, 0, 230, 250, 44, p["body"]) + fingerprint_pad(130, 120, p), 354
    if kind == "bio-usba":
        return usb_a(244, p) + rect(-115, 0, 230, 250, 44, p["body"]) + fingerprint_pad(130, 120, p), 394
    raise ValueError(kind)


def key_image(kind, p):
    drawing, height = key(kind, p)
    return svg(500, 500, group(f"translate(250 {(500 - height) / 2:g})", drawing))


def insert_key():
    gray = "#8E8E93"
    # The pad is cut out of the body so the silhouette works on any background.
    body = ('<path fill-rule="evenodd" fill="%s" d="M8,24 h24 a6,6 0 0 1 6,6 v62 a6,6 0 0 1 -6,6 h-24 '
            'a6,6 0 0 1 -6,-6 v-62 a6,6 0 0 1 6,-6 z M20,53 a8,8 0 1 0 0.01,0 z"/>\n' % gray)
    return svg(40, 128, rect(14, 2, 12, 26, 6, gray) + body + rect(11, 94, 18, 32, 7, gray))


# Tutorial pages

def phone(x, y, w, h, p):
    return rect(x, y, w, h, w * 0.16, p["frame"]) + \
        rect(x + 14, y + 14, w - 28, h - 28, w * 0.16 - 12, p["screen"]) + \
        rect(x + w / 2 - w * 0.14, y + 32, w * 0.28, w * 0.075, w * 0.0375, p["island"])


def arrow(x, y, direction, p):
    """A horizontal arrow whose tip is at x, y and which points left (-1) or right (1)."""
    d = direction
    return f'<path d="M{x - d * 90:g},{y:g} L{x - d * 24:g},{y:g}" stroke="{p["arrow"]}" stroke-width="6" ' \
        f'stroke-linecap="round"/>\n' \
        f'<path d="M{x:g},{y:g} L{x - d * 34:g},{y - 18:g} L{x - d * 34:g},{y + 18:g} z" fill="{p["arrow"]}"/>\n'


def tutorial_plug_in(p):
    drawing, _ = key("usbc-lightning", p)
    # The phone is drawn over the key so the Lightning end looks plugged in.
    return svg(456, 1086, group("translate(228 790) scale(0.62)", drawing) + phone(8, 8, 440, 880, p) +
               arrow(170, 935, 1, p) + arrow(286, 935, -1, p))


def tutorial_nfc(p):
    drawing, _ = key("usbc", p)
    waves = "".join(arc(477, 520, r, 235, 305, p["accent"], 10) for r in (60, 100, 140))
    return svg(954, 1056, phone(237, 440, 480, 960, p) + waves +
               group("translate(477 300) rotate(90) translate(0 -127) scale(0.72)", drawing))


def qr_modules(size=25, seed=7):
    rng = random.Random(seed)
    grid = [[rng.random() < 0.5 for _ in range(size)] for _ in range(size)]
    for ox, oy in ((0, 0), (size - 7, 0), (0, size - 7)):
        for y in range(-1, 8):
            for x in range(-1, 8):
                if 0 <= ox + x < size and 0 <= oy + y < size:
                    ring = max(abs(x - 3), abs(y - 3))
                    grid[oy + y][ox + x] = ring in (0, 1, 3) and 0 <= x < 7 and 0 <= y < 7
    return grid


def tutorial_qr(p):
    out = phone(8, 8, 506, 998, p)
    grid, cell = qr_modules(), 9.6
    left, top = 261 - len(grid) * cell / 2, 507 - len(grid) * cell / 2
    for y, row in enumerate(grid):
        for x, on in enumerate(row):
            if on:
                out += rect(left + x * cell, top + y * cell, cell + 0.3, cell + 0.3, 0, p["ink"])
    corner = 'stroke="%s" stroke-width="10" fill="none" stroke-linecap="round" stroke-linejoin="round"' % p["accent"]
    for sx, sy in ((-1, -1), (1, -1), (-1, 1), (1, 1)):
        cx, cy = 261 + sx * 160, 507 + sy * 160
        out += f'<path d="M{cx:g},{cy - sy * 50:g} L{cx:g},{cy:g} L{cx - sx * 50:g},{cy:g}" {corner}/>\n'
    return svg(522, 1014, out)


SEGMENTS = {  # a b c d e f g
    "0": "abcdef", "1": "bc", "2": "abdeg", "3": "abcdg", "4": "bcfg",
    "5": "acdfg", "6": "acdefg", "7": "abc", "8": "abcdefg", "9": "abcdfg",
}


def digit(x, y, char, color):
    w, h, t = 26, 46, 6
    if char == "1":
        x -= (w - t) / 2  # Center the one instead of leaving a gap on its left.
    segments = {
        "a": (x + t / 2, y, w - t, t), "g": (x + t / 2, y + h / 2 - t / 2, w - t, t), "d": (x + t / 2, y + h - t, w - t, t),
        "f": (x, y + t / 2, t, h / 2 - t / 2), "b": (x + w - t, y + t / 2, t, h / 2 - t / 2),
        "e": (x, y + h / 2, t, h / 2 - t / 2), "c": (x + w - t, y + h / 2, t, h / 2 - t / 2),
    }
    return "".join(rect(*segments[s], t / 2, color) for s in SEGMENTS[char])


def code(x, y, value, color):
    out = ""
    for i, char in enumerate(value):
        out += digit(x + i * 36 + (20 if i >= 3 else 0), y, char, color)
    return out


def timer(cx, cy, fraction, color):
    a = math.radians(-90 + 360 * fraction)
    x, y = cx + 16 * math.cos(a), cy + 16 * math.sin(a)
    large = 1 if fraction > 0.5 else 0
    return f'<circle cx="{cx}" cy="{cy}" r="16" fill="none" stroke="{color}" stroke-width="3"/>\n' \
        f'<path d="M{cx},{cy} L{cx},{cy - 16} A16,16 0 {large} 1 {x:.2f},{y:.2f} z" fill="{color}"/>\n'


def tutorial_accounts(p):
    out = rect(2, 2, 722, 662, 40, p["card_stroke"]) + rect(4, 4, 718, 658, 38, p["card"])
    out += "".join(rect(40, 46 + i * 12, 40, 5, 2.5, p["ink"]) for i in range(3))
    out += rect(644, 56, 34, 5, 2.5, p["ink"]) + rect(658.5, 41.5, 5, 34, 2.5, p["ink"])
    for i, (value, label, fraction) in enumerate((("510326", 330, 0.7), ("689422", 300, 0.45), ("495107", 360, 0.2))):
        y = 130 + i * 170
        out += circle(80, y + 60, 42, p["avatars"][i])
        out += code(150, y + 18, value, p["code"])
        out += rect(150, y + 84, label, 14, 7, p["bar"])
        out += timer(660, y + 60, fraction, p["accent"])
        if i < 2:
            out += rect(36, y + 145, 654, 2, 1, p["bar"])
    return svg(726, 666, out)


# Symbol

def rounded_rect_path(x, y, w, h, r, clockwise=True):
    if clockwise:
        return (f"M{x + r:.3f},{y:.3f} L{x + w - r:.3f},{y:.3f} A{r:.3f},{r:.3f} 0 0 1 {x + w:.3f},{y + r:.3f} "
                f"L{x + w:.3f},{y + h - r:.3f} A{r:.3f},{r:.3f} 0 0 1 {x + w - r:.3f},{y + h:.3f} "
                f"L{x + r:.3f},{y + h:.3f} A{r:.3f},{r:.3f} 0 0 1 {x:.3f},{y + h - r:.3f} "
                f"L{x:.3f},{y + r:.3f} A{r:.3f},{r:.3f} 0 0 1 {x + r:.3f},{y:.3f} z")
    return (f"M{x + r:.3f},{y:.3f} A{r:.3f},{r:.3f} 0 0 0 {x:.3f},{y + r:.3f} "
            f"L{x:.3f},{y + h - r:.3f} A{r:.3f},{r:.3f} 0 0 0 {x + r:.3f},{y + h:.3f} "
            f"L{x + w - r:.3f},{y + h:.3f} A{r:.3f},{r:.3f} 0 0 0 {x + w:.3f},{y + h - r:.3f} "
            f"L{x + w:.3f},{y + r:.3f} A{r:.3f},{r:.3f} 0 0 0 {x + w - r:.3f},{y:.3f} z")


def symbol_glyph(cx, top, scale, stroke):
    """An outlined key with a touch pad and an open connector, sized like the medium scale at scale 1."""
    s, w = scale, stroke
    bw, bh, br = 50 * s + (w - 6.655 * s), 80 * s, 12 * s
    x, bottom = cx - bw / 2, top + 112.4 * s
    body = rounded_rect_path(x, top, bw, bh, br) + " " + \
        rounded_rect_path(x + w, top + w, bw - 2 * w, bh - 2 * w, max(br - w, 1), clockwise=False)
    pad = rounded_rect_path(cx - 10 * s, top + bh / 2 - 10 * s, 20 * s, 20 * s, 6 * s)
    pw, pr, ptop = 28 * s + (w - 6.655 * s), 5 * s, top + bh - w / 2
    plug = (f"M{cx - pw / 2:.3f},{ptop:.3f} L{cx - pw / 2:.3f},{bottom - pr:.3f} "
            f"A{pr:.3f},{pr:.3f} 0 0 0 {cx - pw / 2 + pr:.3f},{bottom:.3f} L{cx + pw / 2 - pr:.3f},{bottom:.3f} "
            f"A{pr:.3f},{pr:.3f} 0 0 0 {cx + pw / 2:.3f},{bottom - pr:.3f} L{cx + pw / 2:.3f},{ptop:.3f} "
            f"L{cx + pw / 2 - w:.3f},{ptop:.3f} L{cx + pw / 2 - w:.3f},{bottom - w:.3f} "
            f"L{cx - pw / 2 + w:.3f},{bottom - w:.3f} L{cx - pw / 2 + w:.3f},{ptop:.3f} z")
    return "".join(f'      <path d="{d}" fill="#000000"/>\n' for d in (body, pad, plug))


# The positions and stroke widths of each weight and scale in the template.
SYMBOL_GROUPS = [
    ("Semibold-L", 2043.27, 1455.373, 1.26, 9.666), ("Regular-L", 1449.84, 1455.373, 1.26, 8.387),
    ("Semibold-M", 2043.27, 1037.749, 1.0, 8.443), ("Regular-M", 1449.84, 1037.749, 1.0, 6.655),
    ("Semibold-S", 2043.27, 619.535, 0.861, 7.284), ("Regular-S", 1449.84, 619.535, 0.861, 5.73),
]


def write_symbol(name, template):
    """Writes a symbol set, reusing the guides and notes of an existing symbol template."""
    groups = "".join(f'    <g id="{group_id}">\n{symbol_glyph(cx, top, scale, stroke)}    </g>\n'
                     for group_id, cx, top, scale, stroke in SYMBOL_GROUPS)
    text = re.sub(r'  <g id="Symbols">.*</g>\s*</svg>', lambda _: f'  <g id="Symbols">\n{groups}  </g>\n</svg>',
                  template, flags=re.S)
    folder = ASSETS / f"Symbols/{name}.symbolset"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"{name}.svg").write_text(text)
    contents = {"info": {"author": "xcode", "version": 1},
                "symbols": [{"filename": f"{name}.svg", "idiom": "universal"}]}
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


# Asset catalog

def write_folder(name):
    folder = ASSETS / name
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def write_imageset(name, light, dark=None):
    folder = ASSETS / name
    if folder.exists():
        for old in folder.iterdir():
            old.unlink()
    folder.mkdir(parents=True, exist_ok=True)
    stem = Path(name).name.removesuffix(".imageset")
    images = [{"filename": f"{stem}.svg", "idiom": "universal"}]
    (folder / f"{stem}.svg").write_text(light)
    if dark is not None:
        images.append({"appearances": [{"appearance": "luminosity", "value": "dark"}],
                       "filename": f"{stem}-dark.svg", "idiom": "universal"})
        (folder / f"{stem}-dark.svg").write_text(dark)
    contents = {"images": images, "info": {"author": "xcode", "version": 1},
                "properties": {"preserves-vector-representation": True}}
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def main():
    write_folder("SecurityKeys")
    write_folder("Tutorial")
    for kind in ("usba", "usbc", "usbc-lightning", "bio-usba", "bio-usbc"):
        write_imageset(f"SecurityKeys/key-{kind}.imageset", key_image(kind, LIGHT), key_image(kind, DARK))
    write_imageset("InsertKey.imageset", insert_key())
    pages = {"tutorial-accounts": tutorial_accounts, "tutorial-plug-in": tutorial_plug_in,
             "tutorial-nfc": tutorial_nfc, "tutorial-qr-code": tutorial_qr}
    for name, draw in pages.items():
        write_imageset(f"Tutorial/{name}.imageset", draw(LIGHT), draw(DARK))
    template = ASSETS / "Symbols/securitykey.symbolset/securitykey.svg"
    write_symbol("securitykey", template.read_text())


if __name__ == "__main__":
    main()
