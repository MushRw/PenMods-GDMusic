#!/usr/bin/env python3
"""生成插件图标：圆角蓝底 + 白色音符（纯 zlib 手写 PNG，无第三方依赖）"""
import zlib, struct, math, os

W = H = 96
ACCENT = (0x4D, 0x8D, 0xF6)
WHITE = (0xFF, 0xFF, 0xFF)


def in_rounded(x, y, x0, y0, x1, y1, r):
    if x < x0 or x > x1 or y < y0 or y > y1:
        return False
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def in_ellipse(x, y, cx, cy, rx, ry):
    return ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1.0


img = [[(0, 0, 0, 0)] * W for _ in range(H)]

for y in range(H):
    for x in range(W):
        # 圆角底
        if not in_rounded(x, y, 3, 3, W - 4, H - 4, 22):
            continue
        c = ACCENT

        # 两个符头
        head = in_ellipse(x, y, 34, 66, 10, 8) or in_ellipse(x, y, 64, 61, 10, 8)
        # 两根符干
        stem = (41 <= x <= 45 and 26 <= y <= 66) or (71 <= x <= 75 and 21 <= y <= 61)
        # 符梁（斜的粗线）
        beam = False
        if 26 <= y <= 38:
            t = (x - 41) / 34.0
            if 0.0 <= t <= 1.0:
                yc = 26 + t * 5 + 5
                beam = abs(y - yc) <= 6
        if head or stem or beam:
            c = WHITE

        # 边缘抗锯齿近似（对 alpha 做一点柔化）
        img[y][x] = (c[0], c[1], c[2], 255)


def write_png(path, pixels, w, h):
    raw = b""
    for y in range(h):
        raw += b"\x00" + b"".join(struct.pack("BBBB", *pixels[y][x]) for x in range(w))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_out = os.path.join(_root, "plugin", "icon.png")
write_png(_out, img, W, H)
print("icon.png written:", W, "x", H, "->", _out)
