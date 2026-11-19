#!/usr/bin/env python3
"""从二进制中提取指定 scheme 的完整 URL 串（带左边界，避免被更长的假 scheme 吞掉）。

用法: extract_schemes2.py <binary> <outdir> <scheme1> [scheme2 ...]
"""
import re
import sys
from collections import defaultdict
from pathlib import Path

CHUNK = 16 * 1024 * 1024
RE_TAIL = rb"[^\x00-\x20\"'<>\\\x7f]{0,220}"


def main():
    path = Path(sys.argv[1])
    outdir = Path(sys.argv[2])
    schemes = sys.argv[3:]
    outdir.mkdir(parents=True, exist_ok=True)

    pats = [
        (s, re.compile(rb"(?<![A-Za-z0-9+.\-])" + s.encode() + rb"://" + RE_TAIL))
        for s in schemes
    ]
    # 无 "//" 的形态
    pats_ns = [
        (s, re.compile(rb"(?<![A-Za-z0-9+.\-])" + s.encode() + rb":/" + RE_TAIL))
        for s in schemes
    ]

    buckets = defaultdict(set)
    carry = b""
    with path.open("rb") as f:
        while True:
            raw = f.read(CHUNK)
            if not raw:
                break
            buf = carry + raw
            for name, pat in pats + pats_ns:
                for m in pat.finditer(buf):
                    buckets[name].add(m.group(0).decode("utf-8", "replace"))
            carry = buf[-8192:]

    total = 0
    for name in sorted(buckets):
        items = sorted(buckets[name])
        total += len(items)
        out = outdir / f"urls_{name}.txt"
        out.write_text("\n".join(items) + "\n", encoding="utf-8")
        print(f"{name:>16}: {len(items):>5} -> {out.name}")
    print(f"{'TOTAL':>16}: {total}")


if __name__ == "__main__":
    main()
