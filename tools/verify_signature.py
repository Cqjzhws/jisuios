#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Mach-O 代码签名槽位校验（CI 门禁）。

为什么需要它：签名「有」不等于签名「对」。v2.5.1 的教训是 —— ad-hoc 签名结构完整、
`codesign -d` 风格的粗略检查全过，但 entitlements 哈希被写进了 special slot -1
（Info.plist 槽位），TrollStore 安装时按 -5 去取 entitlements 取不到，App 就以
普通沙箱身份运行，写 /var/Managed Preferences 全部 EPERM，表现为「保存失败」。

本脚本校验：
  1. SuperBlob / CodeDirectory / entitlements blob 三者结构自洽
  2. entitlements 的哈希确实落在 slot -5（CSSLOT_ENTITLEMENTS），且与 blob 内容相符
  3. 每页代码哈希覆盖 0..codeLimit 且正确（页面大小 = 1<<pageSize）
  4. LC_BUILD_VERSION 平台必须是 iOS
  5. 依赖必须是设备路径（/System/Library 或 /usr/lib），指到 SDK 路径装到手机必崩

用法：
    python3 tools/verify_signature.py <macho> [--entitlements-key KEY ...]
退出码 0 = 通过，1 = 不通过（CI 直接失败）
"""
import struct
import sys

CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171
CSSLOT_ENTITLEMENTS = 5
CSSLOT_DER_ENTITLEMENTS = 7
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_REEXPORT_DYLIB = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_WEAK_DYLIB = 0x80000018
PLATFORM_IOS = 2

DYLIB_CMDS = {LC_LOAD_DYLIB, LC_ID_DYLIB, LC_REEXPORT_DYLIB,
              LC_LOAD_UPWARD_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB}


def load_commands(data):
    ncmds, _ = struct.unpack("<II", data[16:24])
    off = 32
    out = []
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", data[off:off + 8])
        out.append((cmd, off, size))
        off += size
    return out


def fail(msg):
    print("  ✗ " + msg)
    return False


def fatal(msg):
    """致命问题：打印并以退出码 1 结束（fail() 只返回 False，容易被 return 吞掉）。"""
    fail(msg)
    print("  结论: FAIL")
    sys.exit(1)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    want_keys = []
    argv = sys.argv[2:]
    for i, a in enumerate(argv):
        if a == "--entitlements-key" and i + 1 < len(argv):
            want_keys.append(argv[i + 1])

    data = open(path, "rb").read()
    print(f"文件: {path}  {len(data):,} 字节")
    ok = True

    magic, cputype, _, ftype = struct.unpack("<IiiI", data[:16])
    if magic != 0xFEEDFACF:
        fatal("不是 64 位 Mach-O（瘦二进制）")
    cpu = {0x0100000C: "arm64", 0x01000007: "x86_64"}.get(cputype, hex(cputype))
    print(f"  架构: {cpu}  类型: {ftype}")

    cs = None
    platform = None
    deps = []
    for cmd, off, size in load_commands(data):
        if cmd == LC_CODE_SIGNATURE:
            _, _, do, ds = struct.unpack("<IIII", data[off:off + 16])
            cs = (do, ds)
        elif cmd == LC_BUILD_VERSION:
            platform = struct.unpack("<I", data[off + 8:off + 12])[0]
        elif cmd in DYLIB_CMDS and cmd != LC_ID_DYLIB:
            nameoff = struct.unpack("<I", data[off + 8:off + 12])[0]
            deps.append(data[off + nameoff:off + size].split(b"\0")[0].decode("utf-8", "replace"))

    # 4) 平台
    if platform == PLATFORM_IOS:
        print("  平台: iOS ✓")
    else:
        ok = fail(f"平台不是 iOS（platform={platform}），装到手机上会拒绝加载")

    # 5) 依赖路径
    bad = [d for d in deps if not (d.startswith("/System/Library/") or d.startswith("/usr/lib/"))]
    if bad:
        ok = fail("依赖指向非设备路径: " + ", ".join(bad))
    else:
        print(f"  依赖: {len(deps)} 个，全部是设备路径 ✓")

    if not cs:
        fatal("没有 LC_CODE_SIGNATURE")

    do, ds = cs
    blob = data[do:do + ds]
    m, _, cnt = struct.unpack(">III", blob[:12])
    if m != CSMAGIC_EMBEDDED_SIGNATURE:
        fatal(f"SuperBlob magic 错: {hex(m)}")

    cd_off = ent_off = der_off = None
    for i in range(cnt):
        slot, boff = struct.unpack(">II", blob[12 + 8 * i:20 + 8 * i])
        bm = struct.unpack(">I", blob[boff:boff + 4])[0]
        if bm == CSMAGIC_CODEDIRECTORY and slot == 0:
            cd_off = boff
        elif bm == CSMAGIC_EMBEDDED_ENTITLEMENTS:
            ent_off = boff
        elif slot == CSSLOT_DER_ENTITLEMENTS:
            der_off = boff

    if cd_off is None:
        fatal("没有 CodeDirectory(slot 0)")
    is_executable = (ftype == 2)
    if ent_off is None:
        if is_executable:
            fatal("可执行文件没有 entitlements blob，TrollStore 会以默认沙箱身份安装，写 plist 必失败")
        print("  （dylib 不带 entitlements，注入后以宿主 App 权限运行，正常）")

    (_, cd_len, ver, flags, hash_off, ident_off,
     n_special, n_code, code_limit) = struct.unpack(">IIIIIIIII", blob[cd_off:cd_off + 36])
    hash_size, hash_type, _, page_shift = struct.unpack(">BBBB", blob[cd_off + 36:cd_off + 40])
    print(f"  CodeDirectory: ver={hex(ver)} flags={hex(flags)} slots: special={n_special} code={n_code}")
    print(f"  codeLimit={code_limit:,} hashType={hash_type} hashSize={hash_size} pageShift={page_shift}")

    import hashlib
    base = cd_off + hash_off
    ent_blob = b""
    if ent_off is not None:
        if n_special < CSSLOT_ENTITLEMENTS:
            ok = fail(f"special slot 只有 {n_special} 个，装不下 slot -{CSSLOT_ENTITLEMENTS}（entitlements）")

        # 2) entitlements 哈希必须在 -5，且内容相符
        ent_len = struct.unpack(">I", blob[ent_off + 4:ent_off + 8])[0]
        ent_blob = blob[ent_off:ent_off + ent_len]
        ent_hash = hashlib.sha256(ent_blob).digest()
        slot_hash = blob[base - CSSLOT_ENTITLEMENTS * hash_size: base - (CSSLOT_ENTITLEMENTS - 1) * hash_size]
        if slot_hash == ent_hash:
            print(f"  slot -{CSSLOT_ENTITLEMENTS} = entitlements 哈希 ✓ ({ent_hash.hex()[:16]}…)")
        else:
            ok = fail(f"slot -{CSSLOT_ENTITLEMENTS} 与 entitlements blob 不匹配"
                      f"（槽内 {slot_hash.hex()[:16]}… / 应为 {ent_hash.hex()[:16]}…）"
                      " —— 这就是 v2.5.1「保存失败」的成因")
        slot_neg1 = blob[base - hash_size:base]
        if slot_neg1 == ent_hash:
            ok = fail("entitlements 哈希落在了 slot -1（Info.plist 槽位），一定是放错位置了")

    # 3) 逐页哈希
    page = 1 << page_shift
    want_pages = (code_limit + page - 1) // page
    if want_pages != n_code:
        ok = fail(f"code slot 数量不符：标称 {n_code}，codeLimit 需要 {want_pages}")
    bad_pages = 0
    for i in range(min(n_code, want_pages)):
        chunk = data[i * page:min((i + 1) * page, code_limit)]
        if hashlib.sha256(chunk).digest() != blob[base + i * hash_size: base + (i + 1) * hash_size]:
            bad_pages += 1
    if bad_pages:
        ok = fail(f"{bad_pages}/{n_code} 页哈希不对（签名后文件被改过，或被截断）")
    else:
        print(f"  逐页哈希: {n_code} 页全部匹配 ✓")

    # entitlements 关键键
    if want_keys and ent_blob:
        xml = ent_blob[8:]
        miss = [k for k in want_keys if k.encode() not in xml]
        if miss:
            ok = fail("entitlements 缺键: " + ", ".join(miss))
        else:
            print(f"  entitlements 关键键齐全 ✓ ({', '.join(want_keys)})")
    elif want_keys and not ent_blob:
        print("  （无 entitlements，跳过键检查）")
    if der_off is None:
        print("  （无 DER entitlements，iOS 15 以下不需要，可忽略）")

    print("  结论:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
