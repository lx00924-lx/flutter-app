#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""LxAI 品牌图标生成器（纯代码绘制，不依赖任何第三方素材 / 图库）。

用法：
    python tools/make_icons.py            # 生成全部图标（覆盖写入）
    python tools/make_icons.py --dry-run  # 只列出会写入哪些文件

背景（为什么必须用脚本而不是随手贴一张图）：
  App 自 2026-09-18 起，图标一直是**一张第三方动漫插画**（assets/icon/app_icon.png、
  windows/runner/resources/app_icon.ico、Android mipmap 全套都是它），既有版权风险，
  也和安装向导里已经换用的新标识（installer/assets/wizard-*.png）不一致。
  这里用几何图形重绘品牌标识 —— 每个元素都是代码画出来的：

      深藏青圆角方块（左上→右下渐变）
        ├─ 两个浅色节点（左上 / 右下）
        ├─ 一条天蓝色链路把两点连起来
        └─ 链路正中是琥珀色「中继」节点（带光晕）

  它描述的就是本项目的架构：手机 App ── 云端中继 ── 电脑端 Agent。

为什么不用 flutter_launcher_icons：
  pubspec.yaml 里它配的 android 名称是 "launcher_icon"，而 AndroidManifest 引用的是
  @mipmap/ic_launcher —— 跑它只会生成一个**没人引用**的 launcher_icon.png，真正生效的
  图标纹丝不动（这正是"换了图标却没生效"的坑）。而且自适应图标需要「纯色背景」
  与「透明前景」两张图，本脚本一并产出。
"""

from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
FLUTTER = ROOT / "flutter_app"
ANDROID_RES = FLUTTER / "android" / "app" / "src" / "main" / "res"

# ---------------------------------------------------------------------------
# 品牌设计参数（全部是相对画布边长的比例，改这里即可整体调整）
# ---------------------------------------------------------------------------
SQUIRCLE_R = 0.225                     # 圆角方块的圆角半径
BG_A = (0.047, 0.114, 0.196)           # #0C1D32  渐变起点（左上）
BG_B = (0.075, 0.200, 0.318)           # #133351  渐变终点（右下）
DOT_OFF = 0.200                        # 两个节点的中心相对画布中心的对角偏移
DOT_R = 0.088                          # 节点半径
LINE_W = 0.056                         # 链路宽度
LINE_COL = (0.490, 0.827, 0.988)       # #7DD3FC
NODE_R = 0.082                         # 中继节点半径
NODE_CORE_R = 0.034                    # 中继节点内核半径
NODE_COL = (0.984, 0.749, 0.141)       # #FBBF24
NODE_CORE_COL = (0.996, 0.953, 0.780)  # #FEF3C7
GLOW_R = 0.165                         # 中继节点光晕半径
GLOW_A = 0.42                          # 光晕峰值不透明度
DOT_COL = (0.941, 0.976, 1.000)        # #F0F9FF
EDGE_COL = (1.000, 1.000, 1.000)       # 托盘图标描边（深色任务栏上也能看清轮廓）
EDGE_W = 0.022

# 托盘 4 态：只换中继节点的颜色（形状保持品牌一致）
TRAY_STATES = {
    "tray_idle.ico": (0.220, 0.518, 0.973),      # #3884F8 待机（品牌蓝）
    "tray_message.ico": (0.133, 0.773, 0.369),   # #22C55E 有新消息
    "tray_question.ico": (0.984, 0.749, 0.141),  # #FBBF24 等待确认
    "tray_offline.ico": (0.580, 0.639, 0.722),   # #94A3B8 离线
}


def _paint(rgb, alpha, color, mask, opacity=1.0):
    """把 color 以 mask（0..1 覆盖率）合成到预乘 rgb/alpha 上（就地修改）。"""
    sa = mask * opacity
    if not np.any(sa):
        return
    sa3 = sa[:, :, None] if isinstance(color, tuple) else sa[..., None]
    col = np.array(color, np.float32).reshape(1, 1, 3) if isinstance(color, tuple) else color
    rgb *= (1.0 - sa3)
    rgb += col * sa3
    alpha *= (1.0 - sa)
    alpha += sa


def render(size, *, background=True, circle=False, scale=1.0, accent=None,
           edge=False, ss=None):
    """渲染一张 size×size 的图标，返回 uint8 的 (size, size, 4) 非预乘 RGBA。

    background=False → 透明底（Android 自适应图标的「前景」）。
    circle=True     → 圆形底（ic_launcher_round）。
    scale           → 图形的整体缩放（自适应前景要留安全区）。
    accent          → 覆盖中继节点颜色（托盘 4 态用）。
    """
    if ss is None:
        ss = 4 if size <= 512 else 3
    n = size * ss
    out_rgb = np.zeros((size, size, 3), np.float32)
    out_a = np.zeros((size, size), np.float32)
    node_col = accent if accent is not None else NODE_COL
    # 分块渲染：每块的超采样像素数控制在 200 万以内，
    # 避免 3072² 画布上一口气开出几十个上百 MB 的临时数组。
    block = max(1, 2_000_000 // (size * ss * ss))
    for y0 in range(0, size, block):
        y1 = min(size, y0 + block)
        rows = (y1 - y0) * ss
        ys = (np.arange(y0 * ss, y1 * ss, dtype=np.float32) + 0.5) / n
        xs = (np.arange(n, dtype=np.float32) + 0.5) / n
        dx = (xs - 0.5)[None, :]
        dy = (ys - 0.5)[:, None]

        # 图层一律在超采样分辨率上合成（抗锯齿靠随后的均值降采样）
        rgb = np.zeros((rows, n, 3), np.float32)
        alpha = np.zeros((rows, n), np.float32)

        ax, ay = np.abs(dx), np.abs(dy)
        half = 0.5 - SQUIRCLE_R
        qx = np.maximum(ax - half, 0.0)
        qy = np.maximum(ay - half, 0.0)
        body = ((qx * qx + qy * qy) <= SQUIRCLE_R * SQUIRCLE_R).astype(np.float32)
        if circle:
            body = (dx * dx + dy * dy <= 0.25).astype(np.float32) * body

        if background:
            t = np.clip((dx + dy) * 0.5 + 0.5, 0.0, 1.0)[..., None]
            grad = np.array(BG_A, np.float32).reshape(1, 1, 3) * (1.0 - t) \
                + np.array(BG_B, np.float32).reshape(1, 1, 3) * t
            _paint(rgb, alpha, grad, body)

        if edge:
            ehalf = 0.5 - max(SQUIRCLE_R - EDGE_W, 1e-4)
            ex = np.maximum(ax - ehalf, 0.0)
            ey = np.maximum(ay - ehalf, 0.0)
            inner = ((ex * ex + ey * ey) <= max(SQUIRCLE_R - EDGE_W, 1e-4) ** 2).astype(np.float32)
            _paint(rgb, alpha, EDGE_COL, np.clip(body - inner, 0.0, 1.0))

        # ---- 图形本体（按 scale 缩放，便于自适应图标留安全区）----
        gx = dx / scale
        gy = dy / scale

        # 链路：两个节点中心之间的胶囊
        ex_, ey_ = 2.0 * DOT_OFF, 2.0 * DOT_OFF
        tt = np.clip(((gx + DOT_OFF) * ex_ + (gy + DOT_OFF) * ey_) / (ex_ * ex_ + ey_ * ey_), 0.0, 1.0)
        line_d = np.hypot(gx - (-DOT_OFF + tt * ex_), gy - (-DOT_OFF + tt * ey_))
        _paint(rgb, alpha, LINE_COL, (line_d <= LINE_W * 0.5).astype(np.float32))

        # 中继节点光晕（压在链路之上）
        r = np.hypot(gx, gy)
        glow = np.clip((GLOW_R - r) / max(GLOW_R - NODE_R, 1e-6), 0.0, 1.0) ** 1.7
        _paint(rgb, alpha, node_col, (glow * GLOW_A).astype(np.float32))

        # 中继节点本体 + 内核
        _paint(rgb, alpha, node_col, (r <= NODE_R).astype(np.float32))
        _paint(rgb, alpha, NODE_CORE_COL, (r <= NODE_CORE_R).astype(np.float32))

        # 两端节点（盖住链路端头）
        dots = ((np.hypot(gx + DOT_OFF, gy + DOT_OFF) <= DOT_R)
                | (np.hypot(gx - DOT_OFF, gy - DOT_OFF) <= DOT_R)).astype(np.float32)
        _paint(rgb, alpha, DOT_COL, dots)

        out_rgb[y0:y1] = rgb.reshape(y1 - y0, ss, size, ss, 3).mean(axis=(1, 3))
        out_a[y0:y1] = alpha.reshape(y1 - y0, ss, size, ss).mean(axis=(1, 3))

    a8 = np.clip(out_a * 255.0 + 0.5, 0, 255).astype(np.uint8)
    safe = np.maximum(out_a[..., None], 1e-6)
    straight = np.where(out_a[..., None] > 1e-6, out_rgb / safe, 0.0)
    rgb8 = np.clip(straight * 255.0 + 0.5, 0, 255).astype(np.uint8)
    return np.concatenate([rgb8, a8[..., None]], axis=2)


# ---------------------------------------------------------------------------
# 编码：PNG（RGBA8）与 ICO（≤64 用 32bpp DIB，256 用内嵌 PNG）
# ---------------------------------------------------------------------------
def png_bytes(arr):
    h, w, _ = arr.shape
    raw = b"".join(b"\x00" + arr[y].tobytes() for y in range(h))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def dib_bytes(arr):
    h, w, _ = arr.shape
    header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    pixels = arr[:, :, [2, 1, 0, 3]][::-1].tobytes()          # BGRA，自下而上
    mask_row = ((w + 31) // 32) * 4
    return header + pixels + b"\x00" * (mask_row * h)


def write_png(path, arr):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png_bytes(arr))
    return path


def write_ico(path, images):
    """images: [(size, 非预乘 RGBA uint8 数组), ...]"""
    entries, blobs = [], []
    offset = 6 + 16 * len(images)
    for size, arr in images:
        blob = png_bytes(arr) if size >= 256 else dib_bytes(arr)
        entries.append(struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32,
                                   len(blob), offset))
        blobs.append(blob)
        offset += len(blob)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(struct.pack("<HHH", 0, 1, len(images)) + b"".join(entries) + b"".join(blobs))
    return path


# ---------------------------------------------------------------------------
# 生成计划
# ---------------------------------------------------------------------------
ANDROID_DENSITIES = [("mdpi", 1.0), ("hdpi", 1.5), ("xhdpi", 2.0),
                     ("xxhdpi", 3.0), ("xxxhdpi", 4.0)]
WIN_ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]
TRAY_ICO_SIZES = [16, 20, 24, 32, 48, 64]
APP_ICON_PX = 1024
FOREGROUND_SCALE = 0.88          # 自适应图标前景：四周留出安全区


def build(dry_run=False):
    written = []

    def emit(fn, *args, **kwargs):
        written.append(args[0])          # 第一个位置参数就是目标路径
        if not dry_run:
            fn(*args, **kwargs)

    # 1) 源图（Android legacy / iOS / 文档用）
    emit(write_png, FLUTTER / "assets" / "icon" / "app_icon.png",
         render(APP_ICON_PX))
    emit(write_png, FLUTTER / "assets" / "icon" / "app_icon_foreground.png",
         render(APP_ICON_PX, background=False, scale=FOREGROUND_SCALE))

    # 2) Android mipmap：方形 / 圆形 / 自适应前景
    for name, ratio in ANDROID_DENSITIES:
        d = ANDROID_RES / f"mipmap-{name}"
        emit(write_png, d / "ic_launcher.png", render(int(round(48 * ratio))))
        emit(write_png, d / "ic_launcher_round.png",
             render(int(round(48 * ratio)), circle=True))
        emit(write_png, d / "ic_launcher_foreground.png",
             render(int(round(108 * ratio)), background=False, scale=FOREGROUND_SCALE))

    # 3) Windows 程序图标（任务栏 / 资源管理器 / 安装器 SetupIconFile）
    emit(write_ico, FLUTTER / "windows" / "runner" / "resources" / "app_icon.ico",
         [(s, render(s)) for s in WIN_ICO_SIZES])

    # 4) Windows 托盘 4 态
    tray_dir = FLUTTER / "assets" / "icons" / "tray"
    for fname, accent in TRAY_STATES.items():
        emit(write_ico, tray_dir / fname,
             [(s, render(s, accent=accent, edge=True)) for s in TRAY_ICO_SIZES])

    return written


def main():
    dry = "--dry-run" in sys.argv
    files = build(dry_run=dry)
    total = 0
    for f in files:
        rel = f.relative_to(ROOT)
        size = f.stat().st_size if f.exists() else 0
        total += size
        print(f"  {'(dry) ' if dry else ''}{rel}  {size:,} B")
    print(f"\n共 {len(files)} 个文件，合计 {total:,} B"
          + ("（dry-run，未写入）" if dry else ""))


if __name__ == "__main__":
    main()
