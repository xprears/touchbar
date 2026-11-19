#!/usr/bin/env python3
"""微信深链探针：逐条 open 候选 URL，用「仅微信窗口区域」的像素差异判断是否真有反应。

用法: probe.py <urls_file|-> [--wait 2.5]
每行一个 URL；`#` 开头跳过。
输出: out/reverse/probe/<idx>_{before,after}.png + 终端差异报告
"""
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image, ImageChops

ROOT = Path("/Users/Xprears/WorkBuddy/Touch Bar项目")
OUT = ROOT / "out/reverse/probe"
WXSCAN = ROOT / "tools/wxscan"


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, shell=isinstance(cmd, str))


def wx_window():
    """从 wxscan 拿微信主窗口 (x, y, w, h)，屏幕坐标（左上原点，point 单位）"""
    r = run([str(WXSCAN)])
    for line in r.stdout.splitlines():
        line = line.strip()
        if line.startswith("窗口:"):
            parts = line.split()
            kv = {}
            for p in parts[1:]:
                if "=" in p:
                    k, v = p.split("=", 1)
                    kv[k] = float(v)
            return int(kv["x"]), int(kv["y"]), int(kv["w"]), int(kv["h"])
    return None


def grab_full(path):
    run(["screencapture", "-x", str(path)])
    return Image.open(path).convert("RGB")


def crop_window(img, rect):
    x, y, w, h = rect
    scale = img.width / 1440.0  # 逻辑宽度 1440pt -> 实际像素
    l, t = int(x * scale), int(y * scale)
    r, b = int((x + w) * scale), int((y + h) * scale)
    return img.crop((max(0, l), max(0, t), min(img.width, r), min(img.height, b)))


def diff_ratio(a, b):
    if a.size != b.size:
        return 1.0, None
    d = ImageChops.difference(a, b).convert("L")
    hist = d.histogram()
    # 忽略极小噪声（抗锯齿/光标）
    changed = sum(hist[12:])
    total = a.width * a.height
    return changed / total, d


def main():
    src = sys.argv[1]
    wait = 2.5
    if "--wait" in sys.argv:
        wait = float(sys.argv[sys.argv.index("--wait") + 1])

    urls = []
    lines = sys.stdin.read().splitlines() if src == "-" else Path(src).read_text().splitlines()
    for ln in lines:
        ln = ln.strip()
        if ln and not ln.startswith("#"):
            urls.append(ln)

    OUT.mkdir(parents=True, exist_ok=True)
    tmp = Path("/tmp/_probe_full.png")

    run(["open", "-b", "com.tencent.xinWeChat"])
    time.sleep(1.5)
    rect = wx_window()
    if not rect:
        print("!! 取不到微信窗口，退出")
        return
    print(f"微信窗口 rect={rect}\n")

    results = []
    for i, url in enumerate(urls, 1):
        tag = f"{i:02d}"
        run(["open", "-b", "com.tencent.xinWeChat"])
        time.sleep(1.2)
        before = crop_window(grab_full(tmp), wx_window() or rect)
        before.save(OUT / f"{tag}_before.png")

        # ⚠️ 必须带 -b 强制投给微信。裸 `open "<url>"` 会走 LaunchServices 按 scheme 抢注路由：
        #    本机 `search://` 被 Parallels 的「文件资源管理器.app」注册为 Default handler，
        #    一发就会启动/恢复用户的 Windows 11 虚拟机（2026-10-09 实际踩过）。
        r = run(["open", "-b", "com.tencent.xinWeChat", url])
        time.sleep(wait)
        after = crop_window(grab_full(tmp), wx_window() or rect)
        after.save(OUT / f"{tag}_after.png")

        ratio, _ = diff_ratio(before, after)
        verdict = "★ 有反应" if ratio > 0.004 else "  无反应"
        print(f"[{tag}] {verdict}  diff={ratio*100:6.2f}%  rc={r.returncode}  {url}")
        if r.returncode != 0:
            print(f"      stderr: {r.stderr.strip()}")
        results.append((tag, url, ratio))

    print("\n===== 有反应的候选 =====")
    for tag, url, ratio in results:
        if ratio > 0.004:
            print(f"  [{tag}] {ratio*100:6.2f}%  {url}")


if __name__ == "__main__":
    main()
