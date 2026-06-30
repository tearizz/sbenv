#!/bin/bash
set -e
# sign-x86.sh — 签名 x86_64 EFI 组件
# 对 shim 执行 SizeOfImage 扩展 → sbsign → 验证 (无需 fix_reloc)

_current_path=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT=$(dirname "$_current_path")
ARTIFACT="$PROJECT/artifact"
KEYS="$ARTIFACT/keys"

DB_KEY="$KEYS/DB.key"
DB_CERT="$KEYS/DB.crt"

# ---- pre-check ----
[ -f "$DB_KEY" ]  || { echo "[ERROR] missing: $DB_KEY"; exit 1; }
[ -f "$DB_CERT" ] || { echo "[ERROR] missing: $DB_CERT"; exit 1; }
command -v sbsign  >/dev/null 2>&1 || { echo "[ERROR] need sbsigntool: apt install sbsigntool"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] need python3"; exit 1; }

BACKUP_DIR="$ARTIFACT/backup/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

# ---- sign one EFI file ----
sign_efi() {
    local efi="$1"
    local label="${2:-$(basename "$efi")}"

    echo "sign: $label"

    # backup original
    cp -a "$efi" "$BACKUP_DIR/"

    # strip old signature
    sbattach --remove "$efi" 2>/dev/null || true

    # expand SizeOfImage for signature room
    python3 -c "
import struct
with open('$efi', 'rb') as f:
    d = bytearray(f.read())
lfanew = struct.unpack_from('<I', d, 0x3C)[0]
coff   = lfanew + 4
soh    = struct.unpack_from('<H', d, coff + 16)[0]
opt    = coff + 20
sa     = struct.unpack_from('<I', d, opt + 32)[0]
cur    = struct.unpack_from('<I', d, opt + 56)[0]
newsz  = ((len(d) + 1600 + sa - 1) // sa) * sa
if newsz > cur:
    struct.pack_into('<I', d, opt + 56, newsz)
    with open('$efi', 'wb') as f:
        f.write(d)
"

    # sign with DB key
    sbsign --key "$DB_KEY" --cert "$DB_CERT" --output "$efi" "$efi"

    # verify
    if sbverify --cert "$DB_CERT" "$efi" >/dev/null 2>&1; then
        echo "  verify: OK"
    else
        echo "[ERROR] verify failed: $efi"
        exit 1
    fi
}

# ---- shim + MokManager ----
for efi in "$ARTIFACT/shim/shimx64.efi" "$ARTIFACT/shim/mmx64.efi"; do
    [ -f "$efi" ] || { echo "[ERROR] missing: $efi (run shim build first)"; exit 1; }
    sign_efi "$efi"
done

# fallback (optional)
[ -f "$ARTIFACT/shim/fbx64.efi" ] && sign_efi "$ARTIFACT/shim/fbx64.efi"

echo ""
echo "done — backup at $BACKUP_DIR"
