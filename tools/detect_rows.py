#!/usr/bin/env python3
"""发现页列表行检测：不依赖「选中高亮」，直接按文字/图标的"墨迹"行找出行带。

用于 calib.py。比高亮判据稳——实测微信会发现页处于**无选中项**状态
（右侧显示微信 logo 空闲页），此时高亮判据完全失灵。

用法: python3 detect_rows.py <截图png> <窗口宽> <窗口高>
输出: 每行带的中位 y（逻辑 px，距窗口顶部）
"""
import sys

from PIL import Image


def rows(png: Image.Image, ww: float, wh: float, ink_lum: int = 200):
    sy = png.height / wh
    # 列表内容（图标 + 文字）实测只占窗口宽约 8%..19% 这一窄条；
    # 取太宽会把阈值稀释掉，导致一行都检不出（踩过）。
    x0, x1 = int(png.width * 0.08), int(png.width * 0.19)
    span = x1 - x0
    thr = max(4, span // 10)

    counts = []
    for y in range(png.height):
        n = 0
        for x in range(x0, x1, 2):
            r, g, b = png.getpixel((x, y))
            if 0.299 * r + 0.587 * g + 0.114 * b < ink_lum:
                n += 1
        counts.append(n)

    hits = [y for y, n in enumerate(counts) if n >= thr]
    if not hits:
        return []

    # 图标/文字在行内有上下留白，用 25px(图内) 作为行间间隔阈值切段
    bands, start = [], hits[0]
    for i in range(1, len(hits)):
        if hits[i] - hits[i - 1] > 25:
            bands.append((start, hits[i - 1]))
            start = hits[i]
    bands.append((start, hits[-1]))
    return [((a + b) / 2 / sy, (b - a) / sy) for a, b in bands if b - a >= 6]


def main():
    png = Image.open(sys.argv[1]).convert("RGB")
    ww, wh = float(sys.argv[2]), float(sys.argv[3])
    for y, h in rows(png, ww, wh):
        print(f"{y:.1f}\t行高{h:.1f}")


if __name__ == "__main__":
    main()
