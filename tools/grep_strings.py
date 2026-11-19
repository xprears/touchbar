#!/usr/bin/env python3
"""在大二进制里按正则检索可打印字符串（比 strings|grep 可控，且不受 Xcode 许可影响）。

用法: grep_strings.py <binary> <regex> [min_len]
注意: 会自动把 `weixin://` 这种被字符串池粘在一起的碎片切开——这里不做切分，
      只保证不漏；结果需要人工甄别。
"""
import re
import sys
from pathlib import Path

CHUNK = 16 * 1024 * 1024
PRINTABLE = bytes(range(0x20, 0x7F))


def runs(buf: bytes, minlen: int):
    out = []
    cur = bytearray()
    for b in buf:
        if b in PRINTABLE:
            cur.append(b)
        else:
            if len(cur) >= minlen:
                out.append(bytes(cur))
            cur = bytearray()
    if len(cur) >= minlen:
        out.append(bytes(cur))
    return out


def main():
    path = Path(sys.argv[1])
    pat = re.compile(sys.argv[2].encode())
    minlen = int(sys.argv[3]) if len(sys.argv) > 3 else 6

    hits = set()
    carry = b""
    with path.open("rb") as f:
        while True:
            raw = f.read(CHUNK)
            if not raw:
                break
            buf = carry + raw
            for r in runs(buf, minlen):
                if pat.search(r):
                    hits.add(r.decode("utf-8", "replace"))
            carry = buf[-512:]

    for h in sorted(hits):
        print(h)
    print(f"\n--- {len(hits)} 条 ---", file=sys.stderr)


if __name__ == "__main__":
    main()
