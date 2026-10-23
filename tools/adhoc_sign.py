#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Windows 上给 arm64 Mach-O 做 ad-hoc 签名 + 注入 entitlements。

用途：GitHub Actions 里是 `codesign --force --sign - --entitlements entitlements.plist`，
Windows 没有 codesign / ldid，只能手工构造 code signature blob：
  SuperBlob { CodeDirectory(SHA-256), blobWrapper(Entitlements) }
TrollStore 安装时虽然会重签，但它需要用 `ldid -e` 读出原有 entitlements 决定权限；
二进制里完全没有签名段时这一步拿不到东西，权限就退化成默认沙箱。

用法: adhoc_sign.py <macho> <identifier> <entitlements.plist>
"""
import sys, struct, hashlib

CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY      = 0xFADE0C02
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171

CSSLOT_CODEDIRECTORY = 0
CSSLOT_ENTITLEMENTS  = 5

PAGE = 4096
HASH_SIZE = 32
CD_HEADER = 44          # version 0x20001 的基础头长度


def be(*vals):
    return b"".join(struct.pack(">I", v) for v in vals)


def build_entitlements_blob(xml: bytes) -> bytes:
    body = be(CSMAGIC_EMBEDDED_ENTITLEMENTS, 8 + len(xml)) + xml
    return body


def insert_codesig_cmd(buf: bytearray, dataoff: int, datasize: int) -> None:
    """在 load commands 末尾插入 LC_CODE_SIGNATURE（吃掉 headerpad 空间，不移动代码）。"""
    magic, cputype, cpusub, ftype, ncmds, sizeofcmds, flags, reserved = struct.unpack(
        "<IiiIIIII", bytes(buf[:32]))
    assert magic == 0xFEEDFACF, "not a 64-bit Mach-O"

    end = 32 + sizeofcmds
    # LC_CODE_SIGNATURE: cmd, cmdsize, dataoff, datasize
    cmd = struct.pack("<IIII", 0x1D, 16, dataoff, datasize)
    buf[end:end + 16] = cmd
    # header: ncmds(+1), sizeofcmds(+16)
    struct.pack_into("<II", buf, 16, ncmds + 1, sizeofcmds + 16)


def patch_linkedit(buf: bytearray, new_total: int) -> None:
    """__LINKEDIT 要覆盖到签名数据末尾，否则内核不认末尾那段归属。
    传入的是整个文件的最终长度，段长度 = 总长 - fileoff。"""
    magic, cputype, cpusub, ftype, ncmds, sizeofcmds = struct.unpack(
        "<IiiIII", bytes(buf[:24]))
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", bytes(buf[off:off + 8]))
        if cmd == 0x19:  # LC_SEGMENT_64
            segname = bytes(buf[off + 8:off + 24]).split(b"\0")[0]
            if segname == b"__LINKEDIT":
                vmaddr, vmsize, fileoff, filesize = struct.unpack(
                    "<QQQQ", bytes(buf[off + 24:off + 56]))
                new_filesize = new_total - fileoff
                new_vmsize = ((new_filesize + 0x3FFF) // 0x4000) * 0x4000
                # 注意：vmsize 在 +32，fileoff 在 +40，filesize 在 +48。
                # 只改 vmsize 与 filesize，fileoff 必须保持原值。
                struct.pack_into("<Q", buf, off + 32, new_vmsize)
                struct.pack_into("<Q", buf, off + 48, new_filesize)
                return
        off += size
    raise RuntimeError("__LINKEDIT not found")


def sign(path: str, identifier: str, ents_path: str) -> None:
    with open(path, "rb") as f:
        buf = bytearray(f.read())
    with open(ents_path, "rb") as f:
        xml = f.read().strip()

    # 1) 先对齐到 16，签名数据从对齐处开始
    pad = (-len(buf)) % 16
    buf += b"\0" * pad
    sig_off = len(buf)
    code_limit = sig_off

    # 2) 预算签名总长：code slots 数量只取决于 code_limit
    n_code = (code_limit + PAGE - 1) // PAGE
    ident = identifier.encode() + b"\0"
    ident_pad = (-len(ident)) % 4
    ident += b"\0" * ident_pad

    cd_len = CD_HEADER + len(ident) + HASH_SIZE + n_code * HASH_SIZE
    ent_blob = build_entitlements_blob(xml)
    total = 12 + 2 * 8 + cd_len + len(ent_blob)

    # 3) 更新 __LINKEDIT，并插入 LC_CODE_SIGNATURE（都在头部，不动 sig_off）
    patch_linkedit(buf, sig_off + total)
    # 已存在签名段就只改指针，否则插入新命令
    magic, _, _, _, ncmds, sizeofcmds = struct.unpack("<IiiIII", bytes(buf[:24]))
    has_cs = False
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", bytes(buf[off:off + 8]))
        if cmd == 0x1D:
            struct.pack_into("<II", buf, off + 8, sig_off, total)
            has_cs = True
        off += size
    if not has_cs:
        insert_codesig_cmd(buf, sig_off, total)

    # 4) CodeDirectory：special slot -1 放 entitlements 的哈希
    hash_offset = CD_HEADER + len(ident) + HASH_SIZE
    cd = bytearray()
    cd += be(CSMAGIC_CODEDIRECTORY, cd_len, 0x20001, 0x2)   # flags=adhoc
    cd += be(hash_offset, CD_HEADER, 1, n_code)
    cd += be(code_limit)
    cd += bytes([HASH_SIZE, 2, 0, 12])                      # sha256 / platform / page 4096
    cd += be(0)                                             # spare2
    assert len(cd) == CD_HEADER, len(cd)
    cd += ident
    cd += hashlib.sha256(ent_blob).digest()                 # slot -1
    for i in range(n_code):
        page = bytes(buf[i * PAGE:(i + 1) * PAGE])
        cd += hashlib.sha256(page).digest()
    assert len(cd) == cd_len, (len(cd), cd_len)

    # 5) SuperBlob
    sb_len = 12 + 2 * 8 + cd_len + len(ent_blob)
    sb = bytearray()
    sb += be(CSMAGIC_EMBEDDED_SIGNATURE, sb_len, 2)
    sb += be(CSSLOT_CODEDIRECTORY, 12 + 2 * 8)
    sb += be(CSSLOT_ENTITLEMENTS, 12 + 2 * 8 + cd_len)
    sb += cd
    sb += ent_blob
    assert len(sb) == total, (len(sb), total)

    # 6) 落盘
    buf += sb
    with open(path, "wb") as f:
        f.write(buf)

    cdhash = hashlib.sha256(bytes(cd)).hexdigest()
    print("signed      :", path)
    print("size        :", len(buf))
    print("codeLimit   :", code_limit, "slots:", n_code)
    print("entitlements:", len(xml), "bytes")
    print("cdhash      :", cdhash)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(2)
    sign(sys.argv[1], sys.argv[2], sys.argv[3])
