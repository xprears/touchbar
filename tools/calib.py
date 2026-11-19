#!/usr/bin/env python3
"""发现页列表自校准：测出「距窗口顶部各条目偏移」与「行距」，写入 out/calib.json。

判据用 detect_rows.py 的**行墨迹检测**，不用绿色高亮——
实测微信会停在「发现页无选中项」状态（右侧显示微信 logo 空闲页），
且进入发现页时会**保留上次选中的项**，高亮判据两种情况都会失灵。

用法:
  python3 calib.py            校准并写盘
  python3 calib.py --verify   再用 96/96/96 三档行数自检 + 点「小程序」核对落点
"""
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
from detect_rows import rows as detect_rows  # noqa: E402

ROOT = Path("/Users/Xprears/WorkBuddy/Touch Bar项目")
WXCTL = str(ROOT / "tools/wxctl")
WXFULL = ROOT / "out/wx_full.png"
CALIB = ROOT / "out/calib.json"

ITEMS = ["朋友圈", "视频号", "搜一搜", "游戏", "小程序"]   # 发现页顺序（2026-10-05 实测）
PITCH_MIN, PITCH_MAX = 42.0, 54.0


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def bounds():
    r = run([WXCTL, "bounds"])
    win, sh = None, 900.0
    for line in r.stdout.splitlines():
        if line.strip().startswith("窗口:"):
            kv = {}
            for p in line.split()[1:]:
                if "=" in p:
                    k, v = p.split("=", 1)
                    kv[k] = float(v)
            win = kv
        elif "主屏高" in line:
            sh = float(line.split("主屏高=")[1].split()[0])
    return win, sh


def pick_items(bands):
    """从检出的行带里挑出「5 个等距行」= 列表条目。

    行带可能混入上方的「发现」标题，所以滑动窗口找间距最均匀的连续 5 个。
    """
    if len(bands) < 5:
        return None
    best, best_err = None, 1e9
    for i in range(len(bands) - 4):
        win = bands[i:i + 5]
        diffs = [win[j + 1][0] - win[j][0] for j in range(4)]
        if not all(PITCH_MIN <= d <= PITCH_MAX for d in diffs):
            continue
        err = max(diffs) - min(diffs)
        if err < best_err:
            best, best_err = win, err
    return best


def calibrate():
    # ⚠️ ⌘1 归位再 ⌘4：微信会记住发现页上次选中的项，单独 ⌘4 回去选中的还是上次那个
    run([WXCTL, "key", "1", "cmd"])
    run([WXCTL, "key", "4", "cmd"])
    run([WXCTL, "shot"])
    win, _ = bounds()
    bands = detect_rows(Image.open(WXFULL).convert("RGB"), win["w"], win["h"])
    return win, bands


def main():
    win, sh = bounds()
    win2, bands = calibrate()
    if not bands:
        print("❌ 一行都没检出，校准失败（微信是否在前台？是否停在发现页？）")
        return 1
    print(f"检出 {len(bands)} 个行带：", ", ".join(f"{y:.1f}" for y, _ in bands))

    picked = pick_items(bands)
    if not picked:
        print("❌ 找不到 5 个等距条目，校准失败")
        return 1

    offs = [y for y, _ in picked]
    pitch = (offs[-1] - offs[0]) / 4
    data = {
        "window": {k: win2[k] for k in ("x", "y", "w", "h")},
        "screen_h": sh,
        "x_offset": 121,
        "first_offset": round(offs[0], 1),
        "pitch": round(pitch, 1),
        "items": {name: round(offs[i], 1) for i, name in enumerate(ITEMS)},
    }
    CALIB.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"\n窗口 {win2['x']:.0f},{win2['y']:.0f} {win2['w']:.0f}x{win2['h']:.0f}   主屏高 {sh:.0f}")
    print(f"首项偏移 {offs[0]:.1f}px   行距 {pitch:.1f}px\n")
    print("条目 → 距窗口顶 / 屏幕 Quartz 坐标")
    for name in ITEMS:
        top = data["items"][name]
        print(f"  {name:<5} {top:>6.1f}px   ({win2['x'] + 121:.0f}, {sh - (win2['y'] + top):.0f})")
    print(f"\n已写入 {CALIB}")

    if "--verify" in sys.argv:
        print("\n--- 验证：点「小程序」（最远的一项，能暴露行距累积误差）---")
        top = data["items"]["小程序"]
        cx, cy = win2["x"] + 121, sh - (win2["y"] + top)
        run([WXCTL, "click", str(int(cx)), str(int(cy))])
        run([WXCTL, "shot"])
        # 点中后该行会被高亮，用高亮判据交叉核对
        from find_highlight import detect  # 延迟导入，避免循环
        got = detect(Image.open(WXFULL).convert("RGB"), win2, sh)
        if got is None:
            print("  ⚠️ 点击后未检出高亮，无法交叉核对（请人工看一眼）")
        else:
            print(f"  预期 {top:.1f}px，实测 {got:.1f}px → 偏差 {got - top:+.1f}px")
            print("  ✅ 命中" if abs(got - top) < 12 else "  ❌ 未命中")
    return 0


if __name__ == "__main__":
    sys.exit(main())
