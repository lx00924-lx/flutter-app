#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 Windows 托盘图标的 4 个状态（`.ico`，多尺寸 BMP-in-ICO）。

为什么要脚本生成而不是塞几个二进制进仓库：
  图标是"状态语言"的一部分，配色/符号以后大概率还要调（例如新增"正在生成中"），
  有脚本就能一条命令重出、可复现、可 review，而不是几张来历不明的二进制。

4 个状态（越靠上优先级越高，见 lib/services/tray_service.dart 的 TrayStatus）：

    | 状态     | 底色       | 白色符号     | 含义                       |
    |----------|------------|--------------|----------------------------|
    | idle     | #64748B    | 无           | Agent 在线、没有待办       |
    | message  | #22C55E    | 向下小三角   | 有新的 Agent 回复（气泡）  |
    | question | #F59E0B    | 惊叹号       | 等你选择 / 授权（最优先）  |
    | offline  | #E11D48    | 横杠         | 电脑端桥接离线             |

设计约束：16×16 是 Windows 托盘的常见渲染尺寸，所以只用"整块底色 + 一个极简
白色符号"，不画细节；用 4 倍超采样降采样得到平滑边缘。

用法（在 flutter_app 目录下）：
    python tool/gen_tray_icons.py                 # 重新生成 assets/icons/tray/*.ico
    python tool/gen_tray_icons.py --preview       # 额外出一张浅色/深色任务栏预览图
    python tool/gen_tray_icons.py --out 别的目录   # 输出到别处

依赖：仅 Python 标准库（struct / zlib / argparse / pathlib）。
"""

import argparse
import struct
import sys
import zlib
from pathlib import Path

# 超采样倍数：先按 4 倍画，再降采样，边缘才不发毛
SS = 4

STATES = ("idle", "message", "question", "offline")

BASE_COLORS = {
    "idle": "#64748B",
    "message": "#22C55E",
    "question": "#F59E0B",
    "offline": "#E11D48",
}

WHITE = (255, 255, 255, 255)


def hex_color(value: str):
    value = value.lstrip("#")
    return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16), 255)


class Canvas:
    """极简 RGBA 画布：只支持圆、矩形、倒三角三种笔刷（够画这四个图标了）。"""

    def __init__(self, size: int):
        self.size = size
        self.px = [[(0, 0, 0, 0)] * size for _ in range(size)]

    def _put(self, x: int, y: int, color):
        if 0 <= x < self.size and 0 <= y < self.size:
            self.px[y][x] = color

    def circle(self, cx: float, cy: float, r: float, color):
        for y in range(self.size):
            for x in range(self.size):
                if (x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2 <= r * r:
                    self._put(x, y, color)

    def rect(self, x0: float, y0: float, x1: float, y1: float, color):
        for y in range(int(y0), int(y1) + 1):
            for x in range(int(x0), int(x1) + 1):
                self._put(x, y, color)

    def triangle_down(self, cx: float, top: float, half: float, height: float, color):
        for y in range(int(top), int(top + height) + 1):
            t = (y - top) / max(1.0, height)
            w = half * (1 - t)
            for x in range(int(cx - w), int(cx + w) + 1):
                self._put(x, y, color)

    def downsample(self, factor: int):
        n = self.size // factor
        out = [[(0, 0, 0, 0)] * n for _ in range(n)]
        for y in range(n):
            for x in range(n):
                rs = gs = bs = total_a = 0
                for dy in range(factor):
                    for dx in range(factor):
                        r, g, b, a = self.px[y * factor + dy][x * factor + dx]
                        rs += r * a
                        gs += g * a
                        bs += b * a
                        total_a += a
                count = factor * factor
                if total_a == 0:
                    out[y][x] = (0, 0, 0, 0)
                else:
                    out[y][x] = (rs // total_a, gs // total_a, bs // total_a, total_a // count)
        return out


def render(state: str, size: int):
    """画一个状态在指定尺寸下的 RGBA 像素（超采样后降采样）。"""
    canvas = Canvas(size * SS)
    s = size * SS
    base = hex_color(BASE_COLORS[state])
    canvas.circle(s / 2, s / 2, s * 0.47, base)  # 圆底
    if state == "message":  # 向下小三角（气泡）
        canvas.triangle_down(s / 2, s * 0.30, s * 0.20, s * 0.26, WHITE)
    elif state == "question":  # 惊叹号：竖条 + 圆点
        canvas.rect(s * 0.42, s * 0.24, s * 0.58, s * 0.60, WHITE)
        canvas.circle(s / 2, s * 0.73, s * 0.085, WHITE)
    elif state == "offline":  # 横杠
        canvas.rect(s * 0.26, s * 0.43, s * 0.74, s * 0.57, WHITE)
    return canvas.downsample(SS)


def ico_bytes(images) -> bytes:
    """把 [(size, rgba_rows)] 打包成 ICO（BMP-in-ICO，兼容性最好）。"""
    entries, blobs = [], []
    offset = 6 + 16 * len(images)
    for size, rows in images:
        # BITMAPINFOHEADER：高度写两倍，因为后面还跟 AND 掩码
        header = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0, 0, 0, 0, 0, 0)
        xor = bytearray()
        for y in range(size - 1, -1, -1):  # 自下而上
            for x in range(size):
                r, g, b, a = rows[y][x]
                xor += bytes((b, g, r, a))
        row_bytes = ((size + 31) // 32) * 4  # AND 掩码每行按 4 字节对齐
        and_mask = bytearray()
        for y in range(size - 1, -1, -1):
            bits = bytearray(row_bytes)
            for x in range(size):
                if rows[y][x][3] < 128:
                    bits[x // 8] |= 0x80 >> (x % 8)
            and_mask += bits
        blob = header + bytes(xor) + bytes(and_mask)
        blobs.append(blob)
        entries.append(struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(blob), offset))
        offset += len(blob)
    return struct.pack("<HHH", 0, 1, len(images)) + b"".join(entries) + b"".join(blobs)


def png_bytes(rows) -> bytes:
    """把 RGBA 像素写成 PNG（预览图用，标准库 zlib 足够）。"""
    h = len(rows)
    w = len(rows[0])
    raw = b"".join(b"\x00" + b"".join(bytes(px) for px in row) for row in rows)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def preview_sheet(size: int = 48, pad: int = 10):
    """浅色 + 深色任务栏两种背景下的预览图，用来肉眼检查对比度。"""
    icons = {state: render(state, size) for state in STATES}
    cell = size + pad * 2
    width = cell * len(STATES)
    height = cell * 2
    sheet = [[(0, 0, 0, 255)] * width for _ in range(height)]
    for row, bg in enumerate(((244, 244, 245), (24, 24, 27))):
        y0 = row * cell
        for y in range(cell):
            for x in range(width):
                sheet[y0 + y][x] = (bg[0], bg[1], bg[2], 255)
        for i, state in enumerate(STATES):
            x0 = i * cell + pad
            y0i = y0 + pad
            for y in range(size):
                for x in range(size):
                    r, g, b, a = icons[state][y][x]
                    if a == 0:
                        continue
                    dst = sheet[y0i + y][x0 + x]
                    f = a / 255
                    sheet[y0i + y][x0 + x] = (
                        int(r * f + dst[0] * (1 - f)),
                        int(g * f + dst[1] * (1 - f)),
                        int(b * f + dst[2] * (1 - f)),
                        255,
                    )
    return png_bytes(sheet)


def main(argv=None) -> int:
    default_out = Path(__file__).resolve().parents[1] / "assets" / "icons" / "tray"
    parser = argparse.ArgumentParser(description="生成 Windows 托盘 4 态图标")
    parser.add_argument("--out", default=str(default_out), help="输出目录（默认 flutter_app/assets/icons/tray）")
    parser.add_argument("--sizes", default="16,32,48", help="包含的尺寸，逗号分隔（默认 16,32,48）")
    parser.add_argument("--preview", action="store_true", help="额外输出一张预览 PNG 便于肉眼检查")
    args = parser.parse_args(argv)

    sizes = [int(s) for s in str(args.sizes).split(",") if s.strip()]
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    for state in STATES:
        images = [(size, render(state, size)) for size in sizes]
        path = out_dir / f"tray_{state}.ico"
        path.write_bytes(ico_bytes(images))
        print(f"{path}  {path.stat().st_size} bytes")

    if args.preview:
        preview_path = Path(__file__).resolve().parents[1] / "build" / "tray_preview.png"
        preview_path.parent.mkdir(parents=True, exist_ok=True)
        preview_path.write_bytes(preview_sheet())
        print(f"预览图: {preview_path}（上排浅色任务栏，下排深色任务栏）")
        print("顺序: " + " | ".join(STATES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
