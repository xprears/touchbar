#!/usr/bin/env python3
"""穷举按键组合，看能否把「发现」列表的选中项从第 1 项移走。

判据用 find_highlight.py 量出的高亮中心偏移：起点 ≈76px(朋友圈)，
若变成 ≈124 就是移到了视频号（行距 48px）。

用法: python3 keymove_probe.py
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path("/Users/Xprears/WorkBuddy/Touch Bar项目")
WXCTL = str(ROOT / "tools/wxctl")
PY = sys.executable or "/Users/Xprears/.workbuddy/binaries/python/envs/default/bin/python"
FH = str(ROOT / "tools/find_highlight.py")

COMBOS = [
    ["down"], ["down", "cmd"], ["down", "shift"],
    ["right"], ["right", "cmd"], ["right", "shift"],
    ["left"], ["up"],
    ["space"], ["enter"], ["tab"], ["tab", "shift"],
    ["2"], ["3"], ["5", "cmd"], ["6", "cmd"],
]


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def rect():
    r = run([WXCTL, "bounds"])
    for line in r.stdout.splitlines():
        if line.strip().startswith("窗口:"):
            kv = {}
            for p in line.split()[1:]:
                if "=" in p:
                    k, v = p.split("=", 1)
                    kv[k] = float(v)
            return int(kv["x"]), int(kv["y"]), int(kv["w"]), int(kv["h"])
    return None


def highlight_offset():
    r = run([PY, FH, str(ROOT / "out/wx_full.png"),
             *[str(v) for v in rect()], "900"])
    for line in r.stdout.splitlines():
        if "中心距窗口顶部" in line:
            import re
            m = re.search(r"中心距窗口顶部 (\d+)px", line)
            if m:
                return int(m.group(1))
    return None


def main():
    run([WXCTL, "key", "4", "cmd"])
    base = highlight_offset()
    print(f"基线（⌘4 后）：高亮偏移 = {base}px\n")

    moved = []
    for combo in COMBOS:
        run([WXCTL, "key", "4", "cmd"])          # 每次先回发现页
        run([WXCTL, "key"] + combo)
        off = highlight_offset()
        flag = ""
        if off is None:
            flag = "⚠️ 无高亮（可能已离开发现页）"
        elif abs(off - base) > 20:
            flag = f"★ 偏移变了！({base}→{off})"
            moved.append((combo, off))
        print(f"  {'+'.join(combo):<14} → 偏移 {off}px  {flag}")

    print()
    if moved:
        print("===== 能移动选中项的按键 =====")
        for combo, off in moved:
            print(f"  {'+'.join(combo)}  → {off}px")
    else:
        print("没有任何按键组合能移动发现页列表的选中项。")


if __name__ == "__main__":
    main()
