#!/usr/bin/env python3
"""扫描 Mach-O 二进制中的可打印字符串，捞出 URL scheme / 深链候选。

用法: scan_urls.py <binary> [<binary> ...]
输出: 每个二进制命中的候选串（去重、按长度排序）
"""
import re
import sys
from pathlib import Path

CHUNK = 8 * 1024 * 1024  # 8MB
MINLEN = 6

# 只保留「可打印 ASCII」构成的 run
PRINTABLE = bytes(range(0x20, 0x7F))

# 我们要找的线索
PATTERNS = [
    re.compile(rb"[a-zA-Z][a-zA-Z0-9+.\-]{1,20}://[^\x00\s\"'<>\\]{0,300}"),
    re.compile(rb"[a-zA-Z][a-zA-Z0-9+.\-]{1,20}:(?://)?/[a-zA-Z0-9_\-/.]{2,200}"),
]


def runs_from(chunk: bytes):
    """把 chunk 里所有可打印 run 切出来"""
    out = []
    cur = bytearray()
    for b in chunk:
        if b in PRINTABLE:
            cur.append(b)
        else:
            if len(cur) >= MINLEN:
                out.append(bytes(cur))
            cur = bytearray()
    if len(cur) >= MINLEN:
        out.append(bytes(cur))
    return out


def scan(path: Path):
    found = set()
    tail = b""
    with path.open("rb") as f:
        while True:
            chunk = f.read(CHUNK)
            if not chunk:
                break
            # 拼接上一块的尾巴，避免跨块字符串被截断
            buf = tail + chunk
            for run in runs_from(buf):
                low = run.lower()
                # 粗筛：必须含协议分隔符才继续
                if b"://" not in run and b"weixin" not in low and b"wechat" not in low:
                    continue
                for pat in PATTERNS:
                    for m in pat.finditer(run):
                        s = m.group(0)
                        if 6 <= len(s) <= 320:
                            found.add(s)
            tail = buf[-4096:]
    return found


def main():
    allfound = set()
    for arg in sys.argv[1:]:
        p = Path(arg)
        if not p.exists():
            print(f"!! 不存在: {p}", file=sys.stderr)
            continue
        got = scan(p)
        print(f"### {p}  ({len(got)} 条)", file=sys.stderr)
        allfound |= got

    for s in sorted(allfound, key=lambda x: (x.decode("utf-8", "replace"))):
        print(s.decode("utf-8", "replace"))


if __name__ == "__main__":
    main()
