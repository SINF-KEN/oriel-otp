#!/usr/bin/env python3
"""Draws the security key and tutorial artwork as SVG files in the asset catalog.

The drawings are the app's own and use the colors of the app icon. Run from the repository root:

    python3 tools/generate_artwork.py
"""

import json
import math
import random
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
    # One path, with each run of dark modules in a row as a single rectangle.
    runs = ""
    for y, row in enumerate(grid):
        x = 0
        while x < len(row):
            if row[x]:
                end = x
                while end < len(row) and row[end]:
                    end += 1
                runs += f"M{left + x * cell:g} {top + y * cell:g}h{(end - x) * cell:g}v{cell:g}h{-(end - x) * cell:g}z"
                x = end
            else:
                x += 1
    out += f'<path d="{runs}" fill="{p["ink"]}"/>\n'
    corner = 'stroke="%s" stroke-width="10" fill="none" stroke-linecap="round" stroke-linejoin="round"' % p["accent"]
    for sx, sy in ((-1, -1), (1, -1), (-1, 1), (1, 1)):
        cx, cy = 261 + sx * 160, 507 + sy * 160
        out += f'<path d="M{cx:g},{cy - sy * 50:g} L{cx:g},{cy:g} L{cx - sx * 50:g},{cy:g}" {corner}/>\n'
    return svg(522, 1014, out)


# Tabular digits from Inter Medium (SIL Open Font License, https://rsms.me/inter), in font units with the
# baseline at y = 0. Each digit is 1327 units wide and 1490 units tall.
DIGITS = {
    "0": "M663 20Q403 20 264 -180.5Q125 -381 125 -744Q125 -1106 264.5 -1308Q404 -1510 663 -1510Q922 -1510 1061.5 -1308Q1201 -1106 1201 -744Q1201 -381 1062.5 -180.5Q924 20 663 20ZM663 -175Q817 -175 898 -322Q979 -469 979 -744Q979 -1021 898 -1168.5Q817 -1316 663 -1316Q509 -1316 428 -1168.5Q347 -1021 347 -744Q347 -469 428 -322Q509 -175 663 -175Z",
    "1": "M209 0V-189H606V-1283H596L242 -1025V-1254L568 -1490H832V-189H1159V0Z",
    "2": "M173 0V-165L679 -688Q795 -810 855 -895Q915 -980 915 -1078Q915 -1190 839.5 -1254.5Q764 -1319 651 -1319Q532 -1319 461 -1247.5Q390 -1176 390 -1056H171Q171 -1192 234 -1294.5Q297 -1397 406.5 -1453.5Q516 -1510 655 -1510Q797 -1510 904.5 -1454Q1012 -1398 1073 -1302.5Q1134 -1207 1134 -1086Q1134 -1005 1103.5 -926.5Q1073 -848 996.5 -750Q920 -652 781 -512L489 -207V-195H1157V0Z",
    "3": "M658 20Q507 20 389.5 -32Q272 -84 203.5 -176Q135 -268 131 -390H362Q368 -291 452 -233.5Q536 -176 656 -176Q786 -176 870.5 -242.5Q955 -309 955 -417Q955 -528 870 -598.5Q785 -669 632 -669H505V-855H632Q755 -855 832.5 -919.5Q910 -984 910 -1091Q910 -1194 842 -1256.5Q774 -1319 660 -1319Q552 -1319 469 -1261.5Q386 -1204 382 -1102H162Q166 -1223 233.5 -1315Q301 -1407 413.5 -1458.5Q526 -1510 664 -1510Q807 -1510 912.5 -1454Q1018 -1398 1075 -1305.5Q1132 -1213 1132 -1104Q1132 -978 1062 -891.5Q992 -805 875 -774V-763Q1024 -740 1105 -644.5Q1186 -549 1186 -409Q1186 -285 1117.5 -188Q1049 -91 930 -35.5Q811 20 658 20Z",
    "4": "M103 -290V-474L745 -1490H1027V-484H1223V-290H1027V0H808V-290ZM810 -484V-1219H798L341 -496V-484Z",
    "5": "M647 20Q508 20 399 -33Q290 -86 225.5 -179Q161 -272 156 -390H378Q386 -294 463 -233Q540 -172 647 -172Q774 -172 856.5 -258Q939 -344 939 -478Q939 -568 900 -639Q861 -710 793 -750.5Q725 -791 637 -791Q569 -791 501 -767.5Q433 -744 392 -707L182 -737L265 -1490H1088V-1295H456L409 -879H417Q461 -923 533.5 -950.5Q606 -978 690 -978Q826 -978 932.5 -914Q1039 -850 1100.5 -738Q1162 -626 1162 -482Q1162 -337 1096 -223.5Q1030 -110 913.5 -45Q797 20 647 20Z",
    "6": "M677 20Q577 20 479.5 -15.5Q382 -51 303.5 -132.5Q225 -214 178 -352Q131 -490 131 -695Q131 -953 199.5 -1135.5Q268 -1318 395 -1414Q522 -1510 696 -1510Q828 -1510 931.5 -1457.5Q1035 -1405 1100 -1313Q1165 -1221 1182 -1102H958Q936 -1193 869.5 -1251.5Q803 -1310 696 -1310Q532 -1310 441.5 -1168.5Q351 -1027 351 -774H362Q419 -869 516 -922.5Q613 -976 731 -976Q860 -976 965.5 -913Q1071 -850 1133.5 -739.5Q1196 -629 1196 -487Q1196 -344 1131 -229Q1066 -114 949.5 -47Q833 20 677 20ZM676 -172Q760 -172 827.5 -213.5Q895 -255 934.5 -326Q974 -397 974 -484Q974 -570 936 -639.5Q898 -709 831.5 -750Q765 -791 680 -791Q595 -791 527 -748Q459 -705 419 -635Q379 -565 379 -482Q379 -399 417.5 -328.5Q456 -258 523 -215Q590 -172 676 -172Z",
    "7": "M270 0 918 -1283V-1295H168V-1490H1157V-1287L509 0Z",
    "8": "M662 20Q505 20 385.5 -34Q266 -88 198.5 -182Q131 -276 131 -397Q131 -491 170 -571Q209 -651 277.5 -704.5Q346 -758 432 -773V-781Q319 -808 252 -900.5Q185 -993 185 -1113Q185 -1227 246.5 -1316.5Q308 -1406 416 -1458Q524 -1510 662 -1510Q799 -1510 906.5 -1458Q1014 -1406 1076.5 -1316.5Q1139 -1227 1139 -1113Q1139 -993 1071 -900.5Q1003 -808 894 -781V-773Q977 -758 1045.5 -704.5Q1114 -651 1154.5 -571Q1195 -491 1195 -397Q1195 -276 1126.5 -182Q1058 -88 938 -34Q818 20 662 20ZM662 -165Q799 -165 880.5 -233Q962 -301 962 -412Q962 -527 876.5 -601.5Q791 -676 662 -676Q531 -676 446 -602Q361 -528 361 -412Q361 -301 442 -233Q523 -165 662 -165ZM662 -857Q772 -857 844.5 -922Q917 -987 917 -1092Q917 -1197 846 -1260Q775 -1323 662 -1323Q547 -1323 477 -1260Q407 -1197 407 -1092Q407 -987 478 -922Q549 -857 662 -857Z",
    "9": "M632 21Q499 21 395 -32Q291 -85 225.5 -178Q160 -271 144 -391H370Q391 -298 457.5 -238.5Q524 -179 632 -179Q795 -179 886 -321Q977 -463 977 -717H966Q909 -624 812 -569.5Q715 -515 597 -515Q467 -515 361 -578Q255 -641 193 -751.5Q131 -862 131 -1004Q131 -1147 196 -1262.5Q261 -1378 378.5 -1445.5Q496 -1513 653 -1511Q752 -1509 848 -1474Q944 -1439 1023 -1357.5Q1102 -1276 1149 -1139Q1196 -1002 1196 -796Q1196 -537 1127 -354.5Q1058 -172 931.5 -75.5Q805 21 632 21ZM646 -700Q731 -700 799.5 -743.5Q868 -787 908.5 -857.5Q949 -928 949 -1011Q949 -1092 910 -1162Q871 -1232 804 -1275Q737 -1318 651 -1318Q567 -1318 499.5 -1276.5Q432 -1235 393 -1164.5Q354 -1094 354 -1008Q354 -921 391.5 -851.5Q429 -782 495.5 -741Q562 -700 646 -700Z",
}


def code(x, baseline, value, color, height=46):
    """Draws a six digit code in two groups of three, `height` tall."""
    scale = height / 1490
    out = ""
    for i, char in enumerate(value):
        left = x + i * 1327 * scale + (16 if i >= 3 else 0)
        out += f'<path transform="translate({left:.2f} {baseline:g}) scale({scale:.5f})" d="{DIGITS[char]}" ' \
            f'fill="{color}"/>\n'
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
        out += code(150, y + 64, value, p["code"])
        out += rect(150, y + 84, label, 14, 7, p["bar"])
        out += timer(660, y + 60, fraction, p["accent"])
        if i < 2:
            out += rect(36, y + 145, 654, 2, 1, p["bar"])
    return svg(726, 666, out)


# Symbol

def num(v):
    """A coordinate to two decimals, without trailing zeros."""
    return f"{v:.2f}".rstrip("0").rstrip(".")


def rounded_rect_path(x, y, w, h, r, clockwise=True):
    a, n = f"A{num(r)} {num(r)} 0 0 {1 if clockwise else 0} ", num
    if clockwise:
        return (f"M{n(x + r)} {n(y)}H{n(x + w - r)}{a}{n(x + w)} {n(y + r)}V{n(y + h - r)}{a}{n(x + w - r)} {n(y + h)}"
                f"H{n(x + r)}{a}{n(x)} {n(y + h - r)}V{n(y + r)}{a}{n(x + r)} {n(y)}Z")
    return (f"M{n(x + r)} {n(y)}{a}{n(x)} {n(y + r)}V{n(y + h - r)}{a}{n(x + r)} {n(y + h)}"
            f"H{n(x + w - r)}{a}{n(x + w)} {n(y + h - r)}V{n(y + r)}{a}{n(x + w - r)} {n(y)}Z")


def symbol_glyph(cx, top, scale, stroke):
    """An outlined key with a touch pad and an open connector, sized like the medium scale at scale 1."""
    s, w, n = scale, stroke, num
    bw, bh, br = 50 * s + (w - 6.655 * s), 80 * s, 12 * s
    # A short connector, with the glyph moved down by half of what it lost to stay centered where it was.
    top += 7.2 * s
    x, bottom = cx - bw / 2, top + 98 * s
    pw, pr = 28 * s + (w - 6.655 * s), 5 * s
    left, right = cx - pw / 2, cx + pw / 2
    # Xcode fills symbols even-odd, so the body and the connector share one outline instead of overlapping:
    # the connector's sides leave the body's bottom corners where they cross x = cx +/- pw / 2.
    yc = top + bh - br + math.sqrt(br ** 2 - (pw / 2 - (bw / 2 - br)) ** 2)
    ab, ap = f"A{n(br)} {n(br)} 0 0 1 ", f"A{n(pr)} {n(pr)} 0 0 1 "
    outline = (f"M{n(x + br)} {n(top)}H{n(x + bw - br)}{ab}{n(x + bw)} {n(top + br)}V{n(top + bh - br)}"
               f"{ab}{n(right)} {n(yc)}V{n(bottom - pr)}{ap}{n(right - pr)} {n(bottom)}"
               f"H{n(left + pr)}{ap}{n(left)} {n(bottom - pr)}V{n(yc)}{ab}{n(x)} {n(top + bh - br)}"
               f"V{n(top + br)}{ab}{n(x + br)} {n(top)}Z")
    hollow = rounded_rect_path(x + w, top + w, bw - 2 * w, bh - 2 * w, max(br - w, 1), clockwise=False)
    opening = f"M{n(left + w)} {n(top + bh)}V{n(bottom - w)}H{n(right - w)}V{n(top + bh)}Z"
    pad = rounded_rect_path(cx - 10 * s, top + bh / 2 - 10 * s, 20 * s, 20 * s, 6 * s)
    return f'<path d="{outline}{hollow}{opening}"/><path d="{pad}"/>'


# The positions and stroke widths of each weight and scale in Apple's symbol template (v3.0).
SYMBOL_GROUPS = [
    ("Semibold-L", 2043.27, 1455.373, 1.26, 9.666), ("Regular-L", 1449.84, 1455.373, 1.26, 8.387),
    ("Semibold-M", 2043.27, 1037.749, 1.0, 8.443), ("Regular-M", 1449.84, 1037.749, 1.0, 6.655),
    ("Semibold-S", 2043.27, 619.535, 0.861, 7.284), ("Regular-S", 1449.84, 619.535, 0.861, 5.73),
]
# The baseline and cap line of each scale, and the margins of the regular medium glyph.
SYMBOL_GUIDES = {"S": (696, 625.54), "M": (1126, 1055.54), "L": (1556, 1485.54)}
SYMBOL_MARGINS = (1399.77, 1499.92)


def write_symbol(name):
    """Writes a symbol set holding only what Xcode reads from the template: its version, guides and glyphs."""
    guides = "".join(f'<path id="Baseline-{k}" d="M263 {num(b)}H3036"/><path id="Capline-{k}" d="M263 {num(c)}H3036"/>'
                     for k, (b, c) in SYMBOL_GUIDES.items())
    guides += "".join(f'<path id="{side}-margin-Regular-M" d="M{num(m)} 1030.79V1150.12"/>'
                      for side, m in zip(("left", "right"), SYMBOL_MARGINS))
    glyphs = "".join(f'<g id="{group_id}">{symbol_glyph(cx, top, scale, stroke)}</g>\n'
                     for group_id, cx, top, scale, stroke in SYMBOL_GROUPS)
    text = ('<svg xmlns="http://www.w3.org/2000/svg" width="3300" height="2200" viewBox="0 0 3300 2200">\n'
            '<g id="Notes"><text id="template-version">Template v.3.0</text></g>\n'
            f'<g id="Guides" stroke="#27AAE1" stroke-width=".5">{guides}</g>\n'
            f'<g id="Symbols">\n{glyphs}</g>\n</svg>\n')
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
    write_symbol("securitykey")


if __name__ == "__main__":
    main()
