#!/usr/bin/env python3
"""极简 Mach-O 段表解析：列出 arm64 slice 各 section 的 vmaddr/offset/size，
并支持把文件偏移反查所属 section。

用法:
  python3 macho_sections.py <binary>
  python3 macho_sections.py <binary> --at 145852368 149427888
"""
import struct
import sys
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_ARM64 = 0x0100000C


def parse_fat(data):
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic not in (FAT_MAGIC, FAT_MAGIC_64):
        return [(0, len(data), "thin")]
    n = struct.unpack_from(">I", data, 4)[0]
    out = []
    off = 8
    for _ in range(n):
        if magic == FAT_MAGIC:
            cputype, _, foff, size, _ = struct.unpack_from(">iiIII", data, off)
        else:
            cputype, _, foff, size, _, _ = struct.unpack_from(">iiQQII", data, off)
        out.append((foff, size, cputype))
        off += 32 if magic == FAT_MAGIC_64 else 20
    return out


def parse_macho(data, base):
    magic, cputype = struct.unpack_from("<II", data, base)
    if magic != MH_MAGIC_64:
        return None
    ncmds, = struct.unpack_from("<I", data, base + 16)
    p = base + 32
    sections = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, p)
        if cmd == 0x19:  # LC_SEGMENT_64
            segname = data[p + 8:p + 24].rstrip(b"\0").decode("utf-8", "replace")
            nsects, = struct.unpack_from("<I", data, p + 64)
            q = p + 72
            for _ in range(nsects):
                sect = data[q:q + 16].rstrip(b"\0").decode("utf-8", "replace")
                addr, size = struct.unpack_from("<QQ", data, q + 32)
                off, = struct.unpack_from("<I", data, q + 48)
                sections.append({
                    "seg": segname, "sect": sect, "addr": addr,
                    "size": size, "off": off, "end": off + size,
                })
                q += 80
        p += cmdsize
    return sections


def main():
    path = sys.argv[1]
    data = Path(path).read_bytes()
    slices = parse_fat(data)
    print(f"文件 {path}  大小 {len(data)/1e6:.1f} MB  slice 数 {len(slices)}")

    arm = None
    for foff, size, cputype in slices:
        name = {CPU_ARM64: "arm64", 0x01000007: "x86_64"}.get(cputype, hex(cputype) if isinstance(cputype, int) else cputype)
        print(f"  slice @{foff}  size={size/1e6:.1f}MB  {name if isinstance(name,str) else name}")
        if isinstance(cputype, int) and cputype == CPU_ARM64:
            arm = foff
    if arm is None:
        print("!! 没找到 arm64 slice")
        return

    secs = parse_macho(data, arm)
    if not secs:
        print("!! 解析失败")
        return

    print(f"\n{'segment':<16}{'section':<20}{'vmaddr':>14}{'file_off':>14}{'size':>14}")
    for s in secs:
        if s["size"] == 0:
            continue
        print(f"{s['seg']:<16}{s['sect']:<20}{s['addr']:>14}{s['off']:>14}{s['size']:>14}")

    if "--at" in sys.argv:
        offs = [int(x) for x in sys.argv[sys.argv.index("--at") + 1:]]
        print("\n文件偏移反查（注意：偏移是相对整个文件，arm64 slice 要减去 slice 起点）:")
        for o in offs:
            rel = o - arm
            hit = [s for s in secs if s["off"] <= rel < s["end"]]
            if hit:
                s = hit[0]
                print(f"  {o} -> {s['seg']},{s['sect']}  段内偏移 {rel - s['off']}  vmaddr {s['addr'] + rel - s['off']}")
            else:
                print(f"  {o} -> (不在任何 section 内)")


if __name__ == "__main__":
    main()
