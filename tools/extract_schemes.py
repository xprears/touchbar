#!/usr/bin/env python3
"""用正则从二进制里全量提取 scheme 串（ASCII + UTF-8），去重后分类输出。

用法: extract_schemes.py <binary> <outdir>
"""
import re
import sys
from collections import defaultdict
from pathlib import Path

CHUNK = 16 * 1024 * 1024

SCHEMES = [
    b"weixin", b"xweixin", b"wechat", b"xwechat", b"search", b"xweb",
    b"chatbotsearch", b"feedback", b"appbrand", b"wxwork",
]

# 通用 URL 形态
RE_URL = re.compile(
    rb"([A-Za-z][A-Za-z0-9+.\-]{1,24})://([^\x00-\x1f\"'<>\\\s]{0,200})"
)
# scheme:path 形态（无 //）
RE_NOSLASH = re.compile(
    rb"([A-Za-z][A-Za-z0-9+.\-]{1,24}):/([A-Za-z0-9_\-/.]{2,160})"
)


def main():
    path = Path(sys.argv[1])
    outdir = Path(sys.argv[2])
    outdir.mkdir(parents=True, exist_ok=True)

    buckets = defaultdict(set)
    carry = b""

    with path.open("rb") as f:
        while True:
            raw = f.read(CHUNK)
            if not raw:
                break
            buf = carry + raw
            for m in RE_URL.finditer(buf):
                sch = m.group(1)
                if sch.lower() in SCHEMES:
                    buckets[sch.decode().lower()].add(
                        (sch + b"://" + m.group(2)).decode("utf-8", "replace")
                    )
            for m in RE_NOSLASH.finditer(buf):
                sch = m.group(1)
                if sch.lower() in SCHEMES:
                    buckets[sch.decode().lower()].add(
                        (sch + b":/" + m.group(2)).decode("utf-8", "replace")
                    )
            carry = buf[-8192:]

    total = 0
    for sch in sorted(buckets):
        items = sorted(buckets[sch])
        total += len(items)
        out = outdir / f"scheme_{sch}.txt"
        out.write_text("\n".join(items) + "\n", encoding="utf-8")
        print(f"{sch:>16}: {len(items):>5} 条 -> {out.name}")
    print(f"{'TOTAL':>16}: {total}")


if __name__ == "__main__":
    main()
