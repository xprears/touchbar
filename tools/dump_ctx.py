#!/usr/bin/env python3
"""在二进制里定位关键字，并把周边可打印串 dump 出来（看参数格式）。

用法: dump_ctx.py <binary> <keyword> [before] [after]
"""
import sys
from pathlib import Path

CHUNK = 8 * 1024 * 1024
PRINTABLE = set(range(0x20, 0x7F))
MINLEN = 4


def runs_of(data: bytes):
    out = []
    cur = bytearray()
    start = 0
    for i, b in enumerate(data):
        if b in PRINTABLE:
            if not cur:
                start = i
            cur.append(b)
        else:
            if len(cur) >= MINLEN:
                out.append((start, bytes(cur)))
            cur = bytearray()
    if len(cur) >= MINLEN:
        out.append((start, bytes(cur)))
    return out


def main():
    path = Path(sys.argv[1])
    kw = sys.argv[2].encode()
    before = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    after = int(sys.argv[4]) if len(sys.argv) > 4 else 12

    hits = 0
    with path.open("rb") as f:
        base = 0
        carry = b""
        carry_base = 0
        while True:
            chunk = f.read(CHUNK)
            if not chunk:
                break
            buf = carry + chunk
            buf_base = carry_base
            if kw in buf:
                runs = runs_of(buf)
                idxs = [i for i, (_, r) in enumerate(runs) if kw in r]
                for i in idxs:
                    hits += 1
                    lo = max(0, i - before)
                    hi = min(len(runs), i + after + 1)
                    print(f"\n===== hit #{hits} @ file_off ~{buf_base + runs[i][0]} =====")
                    for j in range(lo, hi):
                        mark = ">>" if j == i else "  "
                        off, r = runs[j]
                        print(f"{mark} [+{off:>10}] {r.decode('utf-8','replace')}")
                    if hits >= 40:
                        return
            carry = buf[-4096:]
            carry_base = buf_base + len(buf) - 4096


if __name__ == "__main__":
    main()
