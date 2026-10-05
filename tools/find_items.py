#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从微信窗口截图里精确定位「发现」列表各条目的屏幕坐标。

用法: python3 find_items.py <png> <窗口x> <窗口y> <窗口宽> <窗口高> [面板x0比例] [面板x1比例]

原理：纯 stdlib 解 PNG → 逐行统计指定横向区间内的暗像素 → 聚成行簇 → 换算成屏幕坐标。
注意：screencapture -R 与 CGWindow 坐标一致，都是左下原点，图像首行对应 rect 顶部。
"""
import sys, zlib, struct


def read_png(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', 'not a png'
    pos, idat, w = 8, bytearray(), None
    ihdr = None
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        data = d[pos + 8:pos + 8 + ln]
        if typ == b'IHDR':
            ihdr = struct.unpack('>IIBBBBB', data)
        elif typ == b'IDAT':
            idat += data
        elif typ == b'IEND':
            break
        pos += 12 + ln
    w, h, depth, ctype, _, _, interlace = ihdr
    assert depth == 8 and interlace == 0, f'unsupported depth/interlace {depth}/{interlace}'
    nch = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(bytes(idat))
    stride = w * nch
    out = bytearray(h * stride)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if f == 1:
            for i in range(nch, stride):
                line[i] = (line[i] + line[i - nch]) & 0xFF
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:
            for i in range(stride):
                a = line[i - nch] if i >= nch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:
            for i in range(stride):
                a = line[i - nch] if i >= nch else 0
                b = prev[i]
                c = prev[i - nch] if i >= nch else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, nch, out


def main():
    if len(sys.argv) < 6:
        print(__doc__)
        sys.exit(1)
    png = sys.argv[1]
    wx, wy, ww, wh = map(float, sys.argv[2:6])
    fx0 = float(sys.argv[6]) if len(sys.argv) > 6 else 0.07
    fx1 = float(sys.argv[7]) if len(sys.argv) > 7 else 0.36

    w, h, nch, px = read_png(png)
    x0, x1 = int(w * fx0), int(w * fx1)
    print(f'PNG {w}x{h} 通道{nch}  窗口({wx:.0f},{wy:.0f}) {ww:.0f}x{wh:.0f}')
    print(f'扫描列区间 [{x0},{x1})  (占宽度 {x1-x0}px)')

    dark = []
    for y in range(h):
        c = 0
        base = y * w * nch
        for x in range(x0, x1):
            i = base + x * nch
            lum = 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2]
            if lum < 150:
                c += 1
        dark.append(c)

    thr = max(3, (x1 - x0) // 60)
    clusters, start, last = [], -1, -1
    for y in range(h + 1):
        is_dark = y < h and dark[y] >= thr
        if is_dark:
            if start < 0:
                start = y
            last = y
        elif start >= 0 and y - last > 12:
            if last - start >= 8:
                clusters.append((start, last, (start + last) // 2))
            start = -1

    # 横向取文字/图标中心：簇内暗像素最多的列
    print(f'\n检出 {len(clusters)} 个行簇（阈值 {thr} 暗像素）:')
    print('%-4s %-14s %-8s %-18s' % ('#', '图内y范围', '中心y', '屏幕坐标'))
    sx = ww / w
    sy = wh / h
    for i, (a, b, c) in enumerate(clusters):
        best_x, best_n = x0, -1
        for x in range(x0, x1):
            n = 0
            for y in range(a, b + 1):
                j = (y * w + x) * nch
                lum = 0.299 * px[j] + 0.587 * px[j + 1] + 0.114 * px[j + 2]
                if lum < 150:
                    n += 1
            if n > best_n:
                best_n, best_x = n, x
        X = wx + best_x * sx
        Y = wy + wh - c * sy
        print('%-4d %-14s %-8d (%.0f, %.0f)' % (i, f'{a}-{b}', c, X, Y))


if __name__ == '__main__':
    main()
