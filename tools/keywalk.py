#!/usr/bin/env python3
"""按键序列探针：按顺序发 wxctl 按键，每步截微信窗口并算与上一步的像素差。

用法: python3 keywalk.py "标签:参数" "标签:参数" ...
  例: python3 keywalk.py "base: 4 cmd" "down1: down" "down2: down" "enter: enter"
      参数直接透传给 `wxctl key <...>`；标签用于输出与文件名。
"""
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image, ImageChops

ROOT = Path("/Users/Xprears/WorkBuddy/Touch Bar项目")
OUT = ROOT / "out/reverse/keywalk"
OUT.mkdir(parents=True, exist_ok=True)
TMP = Path("/tmp/_keywalk_full.png")


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def wx_window():
    r = run([str(ROOT / "tools/wxscan")])
    for line in r.stdout.splitlines():
        if line.strip().startswith("窗口:"):
            kv = {}
            for p in line.split()[1:]:
                if "=" in p:
                    k, v = p.split("=", 1)
                    kv[k] = float(v)
            return int(kv["x"]), int(kv["y"]), int(kv["w"]), int(kv["h"])
    return None


def grab(rect):
    run(["screencapture", "-x", str(TMP)])
    img = Image.open(TMP).convert("RGB")
    x, y, w, h = rect
    s = img.width / 1440.0
    return img.crop((int(x * s), int(y * s), int((x + w) * s), int((y + h) * s)))


def ratio(a, b):
    """变化像素占比，阈值取 1/255 —— 选中项高亮这种细微变化也要能测到。"""
    d = ImageChops.difference(a, b).convert("L")
    return sum(d.histogram()[1:]) / (a.width * a.height)


def main():
    steps = [a for a in sys.argv[1:] if ":" in a]
    if not steps:
        print(__doc__)
        return

    run(["open", "-b", "com.tencent.xinWeChat"])
    time.sleep(1.5)
    rect = wx_window()

    prev = None
    base = None
    for i, s in enumerate(steps):
        label, args = s.split(":", 1)
        label, args = label.strip(), args.split()
        r = run([str(ROOT / "tools/wxctl"), "key"] + args)
        time.sleep(1.6)
        cur = grab(rect)
        cur.save(OUT / f"{i:02d}_{label}.png")
        if base is None:
            base = cur
        dv = f"{ratio(prev, cur)*100:6.3f}%" if prev is not None else "   —   "
        db = f"{ratio(base, cur)*100:6.3f}%"
        note = r.stdout.splitlines()[1] if len(r.stdout.splitlines()) > 1 else ""
        print(f"[{i:02d}] {label:<10} vs上一步 {dv}  vs基线 {db}")
        prev = cur

    print(f"\n截图在 {OUT}")


if __name__ == "__main__":
    main()
