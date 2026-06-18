#!/usr/bin/env python3
"""Fix PE .reloc section Page RVA for RISC-V gnu-efi binaries.
The CRT0 computes dummy-label1 which is negative when .data < .reloc in VMA.
This patches the Page RVA to a valid value (0x1000, the .text page)."""
import struct, sys

def fix_reloc(path, outpath=None):
    if outpath is None:
        outpath = path
    with open(path, 'rb') as f:
        d = bytearray(f.read())
    lfanew = struct.unpack_from('<I', d, 0x3C)[0]
    coff = lfanew + 4
    ns = struct.unpack_from('<H', d, coff + 2)[0]
    opt = coff + 20
    soh = struct.unpack_from('<H', d, coff + 16)[0]
    st = opt + soh
    fixed = False
    for i in range(ns):
        o = st + i * 40
        name = d[o:o+8].rstrip(b'\x00').decode()
        if name == '.reloc':
            raw_off = struct.unpack_from('<I', d, o + 20)[0]
            page_rva = struct.unpack_from('<I', d, raw_off)[0]
            if page_rva >= 0x80000000 or page_rva == 0:
                struct.pack_into('<I', d, raw_off, 0x1000)
                print(f"FIXED: {path} .reloc Page RVA 0x{page_rva:08X} -> 0x1000")
                fixed = True
            break
    if fixed:
        with open(outpath, 'wb') as f:
            f.write(d)
    else:
        print(f"SKIP: {path} .reloc Page RVA already valid")
    return fixed

if __name__ == '__main__':
    for p in sys.argv[1:]:
        fix_reloc(p)
