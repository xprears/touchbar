#!/usr/bin/env python3
"""在微信窗口截图里检测「绿色选中高亮」的行位置（相对判据，不依赖固定色值）。

实测高亮色是 (80,169,118)，不是官方绿 #07C160 —— 所以用"明显偏绿"判据。
⚠️ 该判据只在该页**有选中项**时才有效；发现页可能处于"无选中项"状态
（微信会保留上次选中，也会出现整列都不高亮）。要稳的用 detect_rows.py。

用法(CLI): find_highlight.py <截图png> <窗口x> <窗口y> <窗口宽> <窗口高> [主屏高]
"""
import sys

from PIL import Image


def detect(png: Image.Image, win, screen_h: float = 900.0):
    """返回高亮行「中心距窗口顶部」的 px(逻辑)；没有高亮返回 None。
    也接受 win 为 (x, y, w, h) 元组。"""
    if isinstance(win, dict):
        wx, wy, ww, wh = win["x"], win["y"], win["w"], win["h"]
    else:
        wx, wy, ww, wh = win

    sy = png.height / wh
    x0, x1 = int(png.width * 0.11), int(png.width * 0.32)
    thr = max(3, (x1 - x0) // 8)

    hits = []
    for y in range(png.height):
        n = 0
        for x in range(x0, x1, 3):
            r, g, b = png.getpixel((x, y))
            if g > r + 25 and g > b + 20 and g > 90:
                n += 1
        if n >= thr:
            hits.append(y)
    if not hits:
        return None

    segs, start = [], hits[0]
    for i in range(1, len(hits)):
        if hits[i] - hits[i - 1] > 8:
            segs.append((start, hits[i - 1]))
            start = hits[i]
    segs.append((start, hits[-1]))
    segs = [s for s in segs if s[1] - s[0] >= 20]      # 太窄的是图标，不是整行高亮
    if not segs:
        return None
    a, b = max(segs, key=lambda s: s[1] - s[0])
    return (a + b) / 2 / sy


def main():
    png = Image.open(sys.argv[1]).convert("RGB")
    win = tuple(map(float, sys.argv[2:6]))
    off = detect(png, win)
    if off is None:
        print("未检测到绿色高亮（该页可能没有选中态）")
        return
    print(f"高亮行中心距窗口顶部 {off:.0f}px")


if __name__ == "__main__":
    main()
