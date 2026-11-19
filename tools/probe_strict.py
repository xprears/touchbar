#!/usr/bin/env python3
"""严格版深链探针。

相比 probe_pages.py 的三处改进（针对"采样期间被人操作"这个失效模式）：

1. **每次采样都校验干扰**：采图前后都比对「前台是否仍是微信」和「窗口几何是否不变」，
   任一不符 → 该采样作废并重采（最多 3 次）。人为操作电脑会被自动识别出来。
2. **噪声基线**：插入一个**故意伪造的 URL**（`weixin://__no_such_path__`）当零点。
   只有明显超过噪声基线的变化才算"有反应"。
3. **阳性对照**：开跑前和收尾各做一次 ⌘4（已知会切到发现页）。
   若对照测不出变化 ⇒ 说明这一次运行整体不可信，直接作废整个结果。

判定量：窗口左侧 45%（rail + 列表）的像素差。真实换页 ≈ 40%+，内容漂移 ≈ <20%。

用法: python3 probe_strict.py <urls_file> [--repeats N]
"""
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image, ImageChops

ROOT = Path("/Users/Xprears/WorkBuddy/Touch Bar项目")
OUT = ROOT / "out/reverse/strict"
OUT.mkdir(parents=True, exist_ok=True)
WXCTL = str(ROOT / "tools/wxctl")
WXFULL = ROOT / "out/wx_full.png"
LEFT = 0.45
BOGUS = "weixin://__no_such_path__"


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def bounds():
    r = run([WXCTL, "bounds"])
    win = None
    front = ""
    for line in r.stdout.splitlines():
        if line.strip().startswith("窗口:"):
            kv = {}
            for p in line.split()[1:]:
                if "=" in p:
                    k, v = p.split("=", 1)
                    kv[k] = float(v)
            win = (kv["x"], kv["y"], kv["w"], kv["h"])
        elif line.startswith("前台="):
            front = line.split("=", 1)[1].strip()
    return win, front


def shot_left(tag):
    """激活微信→截窗→校验干扰。返回 (左栏图, 窗口矩形) 或 (None, None)"""
    run([WXCTL, "shot"])
    win, front = bounds()
    if front != "com.tencent.xinWeChat" or win is None:
        return None, None
    img = Image.open(WXFULL).convert("RGB")
    img.save(OUT / f"{tag}.png")
    return img.crop((0, 0, int(img.width * LEFT), img.height)), win


def ratio(a, b):
    d = ImageChops.difference(a, b).convert("L")
    return sum(d.histogram()[1:]) / (a.width * a.height)


def key(args):
    run([WXCTL, "key"] + args)


def sample(url):
    """返回 (diff, ok, note)：先 ⌘1 归位，采 A；发 URL；采 B；比左栏。"""
    for attempt in range(3):
        key(["1", "cmd"])
        a, win_a = shot_left("_a")
        if a is None:
            continue
        if url == "__CTRL_CMD4__":
            key(["4", "cmd"])
        else:
            run(["open", "-b", "com.tencent.xinWeChat", url])
        time.sleep(2.6)
        b, win_b = shot_left("_b")
        if b is None:
            continue
        if win_a != win_b:
            continue                      # 窗口被人动过 → 作废重采
        if a.size != b.size:
            continue
        return ratio(a, b), True, f"重试{attempt}次" if attempt else ""
    return None, False, "3 次采样均被干扰"


def main():
    src = sys.argv[1]
    repeats = 2
    if "--repeats" in sys.argv:
        repeats = int(sys.argv[sys.argv.index("--repeats") + 1])
    lines = Path(src).read_text().splitlines()
    urls = [l.strip() for l in lines if l.strip() and not l.strip().startswith("#")]

    print("═══ 阳性对照（开跑前）═══")
    d0, ok0, _ = sample("__CTRL_CMD4__")
    if not ok0 or d0 is None or d0 < 0.15:
        print(f"❌ 阳性对照失败（⌘4 仅 {d0}）⇒ 本次运行不可信，终止")
        return 1
    print(f"✅ ⌘4 换页差异 {d0*100:.1f}%（探针工作正常）\n")

    print("═══ 噪声基线（伪造 URL）═══")
    noises = []
    for i in range(repeats):
        d, ok, note = sample(BOGUS)
        if ok:
            noises.append(d)
        print(f"  第{i+1}次: {d*100:5.2f}%" if ok else f"  第{i+1}次: 作废 ({note})")
    noise = max(noises) if noises else 0.05
    thr = noise + 0.15
    print(f"基线取最大 {noise*100:.2f}%  ⇒ 判定阈值 {thr*100:.2f}%\n")

    print("═══ 候选 URL ═══")
    results = []
    for url in urls:
        ds = []
        for _ in range(repeats):
            d, ok, note = sample(url)
            if ok:
                ds.append(d)
        if not ds:
            print(f"  ⚠️ 作废        {url}")
            continue
        dmax = max(ds)
        verdict = "★ 有反应" if dmax > thr else "  无反应"
        print(f"  {verdict} {dmax*100:5.2f}%  (n={len(ds)})  {url}")
        results.append((url, dmax))

    print("\n═══ 阳性对照（收尾）═══")
    d1, ok1, _ = sample("__CTRL_CMD4__")
    if ok1 and d1 is not None and d1 >= 0.15:
        print(f"✅ ⌘4 换页差异 {d1*100:.1f}%（全程探针有效）")
        trust = True
    else:
        print(f"❌ 收尾对照失败 ⇒ 后半段结果不可信")
        trust = False

    print("\n═══ 汇总 ═══")
    hits = [u for u, d in results if d > thr]
    if hits:
        for u in hits:
            print(f"  ★ {u}")
    else:
        print("  无任何候选超过阈值")
    print(f"\n本次运行{'可信' if trust else '不可信'}   截图在 {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
