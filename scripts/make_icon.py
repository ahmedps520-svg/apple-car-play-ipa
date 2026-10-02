#!/usr/bin/env python3
"""Draws DriveIn's 1024x1024 app icon (a drive-in screen with a play button) as a PNG.

Pure Python (zlib + struct), no dependencies:
    python3 scripts/make_icon.py DriveIn/Assets.xcassets/AppIcon.appiconset/AppIcon.png
"""
import math
import struct
import sys
import zlib

SIZE = 1024


def smoothstep(edge0, edge1, x):
    t = min(max((x - edge0) / (edge1 - edge0), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def rounded_rect_sd(px, py, cx, cy, hw, hh, r):
    """Signed distance to a rounded rectangle centred at (cx, cy)."""
    qx = abs(px - cx) - (hw - r)
    qy = abs(py - cy) - (hh - r)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    return outside + inside - r


def triangle_sd(px, py, a, b, c):
    """Signed distance to triangle abc (negative inside)."""
    def edge(p0, p1):
        ex, ey = p1[0] - p0[0], p1[1] - p0[1]
        wx, wy = px - p0[0], py - p0[1]
        t = min(max((wx * ex + wy * ey) / (ex * ex + ey * ey), 0.0), 1.0)
        dx, dy = wx - ex * t, wy - ey * t
        return dx * dx + dy * dy, ex * wy - ey * wx

    d0, s0 = edge(a, b)
    d1, s1 = edge(b, c)
    d2, s2 = edge(c, a)
    distance = math.sqrt(min(d0, d1, d2))
    inside = (s0 >= 0 and s1 >= 0 and s2 >= 0) or (s0 <= 0 and s1 <= 0 and s2 <= 0)
    return -distance if inside else distance


def mix(c1, c2, t):
    return tuple(c1[i] + (c2[i] - c1[i]) * t for i in range(3))


def pixel(x, y):
    u, v = x / SIZE, y / SIZE
    # Night-sky gradient background.
    color = mix((0.07, 0.08, 0.20), (0.36, 0.10, 0.36), v)
    color = mix(color, (0.98, 0.42, 0.20), smoothstep(0.55, 1.0, v) * 0.55)

    # Ground / road band.
    road = smoothstep(0.78, 0.80, v)
    color = mix(color, (0.10, 0.10, 0.13), road)

    # Big screen with a warm glow.
    screen = rounded_rect_sd(x, y, 512, 430, 360, 230, 60)
    glow = math.exp(-max(screen, 0.0) / 60.0) * 0.35
    color = mix(color, (1.0, 0.62, 0.18), glow)
    screen_fill = mix((1.0, 0.78, 0.32), (1.0, 0.45, 0.25), v)
    color = mix(color, screen_fill, 1.0 - smoothstep(-1.5, 1.5, screen))

    # Screen posts.
    for post_x in (300, 724):
        post = rounded_rect_sd(x, y, post_x, 740, 16, 80, 8)
        color = mix(color, (0.12, 0.12, 0.16), 1.0 - smoothstep(-1.5, 1.5, post))

    # Play triangle.
    tri = triangle_sd(x, y, (450, 330), (450, 530), (610, 430))
    color = mix(color, (1.0, 1.0, 1.0), 1.0 - smoothstep(-1.5, 1.5, tri))

    # Dashed lane markings on the road.
    if v > 0.86:
        lane = rounded_rect_sd(x, y, 512 + 0 * u, 930, 46, 10, 10)
        for offset in (-300, 0, 300):
            lane = min(lane, rounded_rect_sd(x, y, 512 + offset, 930, 46, 10, 10))
        color = mix(color, (0.95, 0.85, 0.45), 1.0 - smoothstep(-1.5, 1.5, lane))
    return color


def write_png(path, width, height, rows):
    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


def main():
    output = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png"
    rows = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            r, g, b = pixel(x + 0.5, y + 0.5)
            row.extend((int(min(max(r, 0), 1) * 255 + 0.5), int(min(max(g, 0), 1) * 255 + 0.5), int(min(max(b, 0), 1) * 255 + 0.5)))
        rows.append(row)
    write_png(output, SIZE, SIZE, rows)
    print("wrote", output)


if __name__ == "__main__":
    main()
