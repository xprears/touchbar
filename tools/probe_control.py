#!/usr/bin/env python3
"""验证探针灵敏度：以 ⌘4（朋友圈）这种确定会跳转的操作做对照。"""
import subprocess
import time
from pathlib import Path

from PIL import Image, ImageChops

ROOT = Path("/Users/Xprears/WorkBuddy/Touch Bar项目")
OUT = ROOT / "out/reverse/probe"
OUT.mkdir(parents=True, exist_ok=True)
TMP = Path("/tmp/_ctl_full.png")


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


def grab():
    run(["screencapture", "-x", str(TMP)])
    img = Image.open(TMP).convert("RGB")
    x, y, w, h = wx_window()
    s = img.width / 1440.0
    return img.crop((int(x * s), int(y * s), int((x + w) * s), int((y + h) * s)))


def ratio(a, b):
    d = ImageChops.difference(a, b).convert("L")
    return sum(d.histogram()[12:]) / (a.width * a.height)


run(["open", "-b", "com.tencent.xinWeChat"])
time.sleep(2)
before = grab()
before.save(OUT / "ctl_before.png")

r = run([str(ROOT / "tools/wxctl"), "key", "4", "cmd"])
print(r.stdout.strip())

time.sleep(2.5)
after = grab()
after.save(OUT / "ctl_after.png")

print(f"\n⌘4 前后像素差异 = {ratio(before, after)*100:.2f}%")
print("（应显著 >0.4%，否则探针不可信）")
