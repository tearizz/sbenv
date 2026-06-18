#!/bin/bash
set -e
# =============================================================================
# sign_all.sh — RISC-V UEFI Secure Boot 统一签名脚本
#
# 在运行 RiscV_OpenEuler_New.sh 构建磁盘镜像之前执行，
# 对所有 EFI 组件执行 fix_reloc → SizeOfImage 扩展 → 签名 → 验证。
#
# 用法:
#   ./script/sign_all.sh                # 签名所有组件
#   ./script/sign_all.sh --verify-only  # 仅验证不签名
#
# 签名后文件直接覆盖原文件，签名前自动备份到 artifact/backup/。
# =============================================================================

COLOR_INFO='\033[0;32m'
COLOR_WARN='\033[1;33m'
COLOR_ERROR='\033[0;31m'
COLOR_RESET='\033[0m'

log_info()  { printf "${COLOR_INFO}[INFO] %s${COLOR_RESET}\n" "$*"; }
log_warn()  { printf "${COLOR_WARN}[WARN] %s${COLOR_RESET}\n" "$*"; }
log_error() { printf "${COLOR_ERROR}[ERROR] %s${COLOR_RESET}\n" "$*"; exit 1; }

_current_path=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
_secureboot_path=$(dirname "$_current_path")
ARTIFACT="$_secureboot_path/artifact"
KEYS="$ARTIFACT/keys"
FIX_RELOC="$_current_path/fix_reloc.py"

# 密钥
DB_KEY="$KEYS/DB.key"
DB_CERT="$KEYS/DB.crt"

# 输出目录
SHIM_DIR="$ARTIFACT/shim"
DRIVERS_DIR="$ARTIFACT/drivers"
BACKUP_DIR="$ARTIFACT/backup/$(date +%Y%m%d_%H%M%S)"

VERIFY_ONLY=false
if [ "${1:-}" = "--verify-only" ]; then
    VERIFY_ONLY=true
    log_info "仅验证模式，不签名"
fi

# ---------------------------------------------------------------------------
# 预检
# ---------------------------------------------------------------------------
for f in "$DB_KEY" "$DB_CERT" "$FIX_RELOC"; do
    [ -f "$f" ] || log_error "缺少文件: $f"
done
command -v sbsign >/dev/null 2>&1  || log_error "请安装 sbsigntool: apt install sbsigntool"
command -v python3 >/dev/null 2>&1 || log_error "需要 python3"
command -v riscv64-linux-gnu-objcopy >/dev/null 2>&1 || log_error "需要 riscv64-linux-gnu-objcopy"

# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

# 扩展 PE SizeOfImage，为签名留空间（sbsign 不会自动更新 SizeOfImage）
expand_size_of_image() {
    local efi="$1"
    python3 -c "
import struct
with open('$efi', 'rb') as f:
    d = bytearray(f.read())
lfanew  = struct.unpack_from('<I', d, 0x3C)[0]
coff    = lfanew + 4
soh     = struct.unpack_from('<H', d, coff + 16)[0]
opt     = coff + 20
sa      = struct.unpack_from('<I', d, opt + 32)[0]
current = struct.unpack_from('<I', d, opt + 56)[0]
new     = ((len(d) + 1600 + sa - 1) // sa) * sa
if new > current:
    struct.pack_into('<I', d, opt + 56, new)
    with open('$efi', 'wb') as f:
        f.write(d)
    print(f'SizeOfImage: 0x{current:08X} -> 0x{new:08X}', end='')
else:
    print(f'SizeOfImage: 0x{current:08X} (already sufficient)', end='')
"
}

# fix .reloc Page RVA 负值问题
do_fix_reloc() {
    local efi="$1"
    python3 "$FIX_RELOC" "$efi" 2>/dev/null || true
}

# 签名单个 EFI 文件
sign_efi() {
    local efi="$1"
    local label="${2:-$(basename "$efi")}"

    if $VERIFY_ONLY; then
        if sbverify --cert "$DB_CERT" "$efi" >/dev/null 2>&1; then
            log_info "验证通过: $label"
        else
            log_warn "验证失败: $label"
        fi
        return
    fi

    log_info "签名: $label"

    # 1. 移除已有签名（fix_reloc 和 SizeOfImage 修改会破坏旧签名 hash）
    sbattach --remove "$efi" 2>/dev/null || true

    # 2. fix_reloc（修改 PE 的 .reloc 段）
    do_fix_reloc "$efi"

    # 3. 扩展 SizeOfImage（为签名留空间）
    expand_size_of_image "$efi"

    # 4. sbsign 签名
    if ! sbsign --key "$DB_KEY" --cert "$DB_CERT" --output "$efi" "$efi" 2>/dev/null; then
        log_error "签名失败: $efi"
    fi

    # 4. 验证
    if sbverify --cert "$DB_CERT" "$efi" >/dev/null 2>&1; then
        log_info "签名验证通过: $label"
    else
        log_error "签名验证失败: $efi"
    fi
}

# ---------------------------------------------------------------------------
# 备份
# ---------------------------------------------------------------------------
backup_file() {
    local src="$1"
    if [ -f "$src" ]; then
        mkdir -p "$BACKUP_DIR"
        cp -a "$src" "$BACKUP_DIR/"
    fi
}

# =============================================================================
# 阶段 1: Shim + MokManager + Fallback
# =============================================================================
log_info "============================================"
log_info "阶段 1/2: Shim 组件签名"
log_info "============================================"

for efi in "$SHIM_DIR/shimriscv64.efi" "$SHIM_DIR/mmriscv64.efi" "$SHIM_DIR/fbriscv64.efi"; do
    if [ -f "$efi" ]; then
        backup_file "$efi"
        sign_efi "$efi"
    else
        [ "$(basename "$efi")" = "fbriscv64.efi" ] && continue  # fallback 可选
        log_error "缺少文件: $efi"
    fi
done

# =============================================================================
# 阶段 2: 网络驱动 (如果固件未包含 Hash2DxeCrypto/TcpDxe/HttpDxe)
# =============================================================================
log_info ""
log_info "============================================"
log_info "阶段 2/2: 网络驱动签名"
log_info "============================================"

DRIVER_COUNT=0
for efi in "$DRIVERS_DIR/Hash2DxeCrypto.efi" "$DRIVERS_DIR/TcpDxe.efi" "$DRIVERS_DIR/HttpDxe.efi"; do
    if [ -f "$efi" ]; then
        backup_file "$efi"
        sign_efi "$efi"
        DRIVER_COUNT=$((DRIVER_COUNT+1))
    else
        log_warn "驱动缺失 (非致命): $efi"
    fi
done

if [ $DRIVER_COUNT -eq 0 ]; then
    log_warn "未发现驱动文件 — 假设固件已将网络驱动编译进 Flash"
    log_warn "如果启动时网络栈不完整，请从 EDK2 Build 目录提取驱动后重新运行本脚本"
fi

# =============================================================================
# 完成
# =============================================================================
log_info ""
log_info "============================================"
log_info "签名完成"
log_info "============================================"
log_info "签名后文件位置:"
for efi in "$SHIM_DIR"/*.efi "$DRIVERS_DIR"/*.efi; do
    [ -f "$efi" ] || continue
    STATUS=$(sbverify --cert "$DB_CERT" "$efi" 2>&1 | grep -c 'Signature verification OK' || echo 0)
    if [ "$STATUS" -gt 0 ] 2>/dev/null; then
        printf "  ✅ %s\n" "$efi"
    else
        printf "  ❌ %s (未签名!)\n" "$efi"
    fi
done
log_info "备份目录: $BACKUP_DIR"
log_info ""
log_info "下一步: 运行 RiscV_OpenEuler_New.sh 构建磁盘镜像"
