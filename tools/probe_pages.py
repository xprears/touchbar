#!/usr/bin/env python3
"""深链落点判读（稳健版）。

相比上一版的两处修正：
  1. 采图改用 `wxctl shot`（它内部先 activate() 微信，再 -R 截微信窗口），
     不再自己 screencapture——否则微信没到前台时会截到别的窗口（实测踩过）。
  2. 每次采图都校验 wxctl 报的「前台=com.tencent.xinWeChat」，不满足就重试/标记无效。

只比窗口左侧 45%（rail + 列表），右侧内容区随时间变化不可比。

用法: python3 probe_pages.py <urls_file|-> [--wait 2.5]
"""
import shutil
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image, ImageChops

ROOT = Path("/Users/Xprears/WorkBuddy/Touch Bar项目")
OUT = ROOT / "out/reverse/pages"
OUT.mkdir(parents=True, exist_ok=True)
WXCTL = str(ROOT / "tools/wxctl")
WXFULL = ROOT / "out/wx_full.png"

REFS = [("聊天", ["1", "cmd"]), ("通讯录", ["2", "cmd"]),
        ("收藏", ["3", "cmd"]), ("发现", ["4", "cmd"])]
LEFT = 0.45


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def shot(tag):
    """activate 微信 → 截整窗 → 校验前台。返回 (left_crop, full, ok)"""
    for attempt in range(3):
        r = run([WXCTL, "shot"])
        front_ok = "前台=com.tencent.xinWeChat" in r.stdout
        if front_ok and WXFULL.exists():
            img = Image.open(WXFULL).convert("RGB")
            shutil.copy(WXFULL, OUT / f"{tag}.png")
            return img.crop((0, 0, int(img.width * LEFT), img.height)), img, True
        time.sleep(1.0)
    return None, None, False


def ratio(a, b):
    d = ImageChops.difference(a, b).convert("L")
    return sum(d.histogram()[1:]) / (a.width * a.height)


def key(args):
    run([WXCTL, "key"] + args)
    time.sleep(1.5)


def main():
    src = sys.argv[1]
    wait = 2.5
    if "--wait" in sys.argv:
        wait = float(sys.argv[sys.argv.index("--wait") + 1])
    lines = sys.stdin.read().splitlines() if src == "-" else Path(src).read_text().splitlines()
    urls = [l.strip() for l in lines if l.strip() and not l.strip().startswith("#")]

    run(["open", "-b", "com.tencent.xinWeChat"])
    time.sleep(1.5)

    refs = {}
    for name, args in REFS:
        key(args)
        left, full, ok = shot(f"ref_{name}")
        if not ok:
            print(f"!! 参照模板「{name}」采图失败（微信未到前台）")
            return
        refs[name] = left
    print("参照模板已采：", "、".join(refs), "\n")

    for i, url in enumerate(urls, 1):
        key(["1", "cmd"])                              # 归位到聊天页
        r = run(["open", "-b", "com.tencent.xinWeChat", url])
        time.sleep(wait)
        tag = f"{i:02d}_after"
        left, full, ok = shot(tag)
        if not ok:
            print(f"[{i:02d}] ⚠️ 采图无效（微信未到前台）   {url}")
            continue
        scores = sorted(((ratio(left, refs[n]), n) for n in refs))
        best = scores[0]
        verdict = f"≈{best[1]}" if best[0] < 0.12 else "无可比页面"
        detail = "  ".join(f"{n}:{v*100:5.1f}%" for v, n in scores)
        print(f"[{i:02d}] {verdict:<12} {detail}   {url}")

    print(f"\n截图在 {OUT}")


if __name__ == "__main__":
    main()
