#!/bin/bash
set -e
# =============================================================================
# RISC-V Secure Boot 磁盘镜像构建脚本
#
# 在 sign_all.sh 签名完成后执行，完成以下工作：
#   1) 创建 GPT 磁盘 (ESP + rootfs)
#   2) 部署 Shim + GRUB + 网络驱动 + startup.nsh 到 ESP
#   3) 安装 OpenEuler RISC-V rootfs (本地 → Package Repo → Docker)
#   4) 用 RISC-V 原生 grub2-mkimage (qemu-user) 构建 GRUB
#   5) 生成 QEMU virt DTB
#   6) 签名 GRUB + 内核
#
# 前置依赖: sign_all.sh 
# 用法:
#   sudo ./script/images/RiscV_OpenEuler_New.sh          # 离线模式 (默认)
#   sudo ./script/images/RiscV_OpenEuler_New.sh --docker # Docker 在线模式 (跳过离线备份)
#
# rootfs 配置优先级:
#   1. 本地 artifact/oerv_rootfs_backup.tar.gz
#   2. GitLab Package Registry 下载 (需设置 GITLAB_PROJECT + GITLAB_TOKEN 环境变量)
#   3. Docker 在线安装 (兜底, 需网络)
# =============================================================================

# ----[ 日志函数 ]------------------------------------------------------------
YELLOW='\033[0;33m' RED='\033[0;31m' BLUE='\033[0;34m' WHITE='\033[0m'
_step=0
_step()  { ((++_step)); printf '%s[%02d] %s%s\n' "$YELLOW" "$_step" "$*" "$WHITE"; }
_info()  { printf '%s%s%s\n' "$BLUE" "$*" "$WHITE"; }
_die()   { printf '%s%s%s\n' "$RED" "$*" "$WHITE"; exit 1; }

# ----[ 路径解析 ]------------------------------------------------------------
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
WS=$(dirname "$(dirname "$SELF_DIR")")           # all_new_riscv/
ARTIFACT="$WS/artifact"

# ----[ 输入文件 (均由 sign_all.sh 提前签名) ]---------------------------------
SHIM="$ARTIFACT/shim/shimriscv64.efi"
MM="$ARTIFACT/shim/mmriscv64.efi"
CSV="$ARTIFACT/shim/BOOTRISCV64.CSV"

DRV_HASH2="$ARTIFACT/drivers/Hash2DxeCrypto.efi"
DRV_TCP="$ARTIFACT/drivers/TcpDxe.efi"
DRV_HTTP="$ARTIFACT/drivers/HttpDxe.efi"

DB_KEY="$ARTIFACT/keys/DB.key"
DB_CRT="$ARTIFACT/keys/DB.crt"

FIX_RELOC="$WS/script/fix_reloc.py"

# ----[ 输出 ]----------------------------------------------------------------
DISK="$ARTIFACT/images/RiscV_OpenEuler.img"
DISK_TMP="${DISK}.tmp.$$"

# ----[ 预检: 所有依赖文件必须存在 ]-------------------------------------------
for f in "$SHIM" "$MM" "$CSV" "$DB_KEY" "$DB_CRT" \
         "$DRV_HASH2" "$DRV_TCP" "$DRV_HTTP"; do
    [ -f "$f" ] || _die "缺少文件: $f  (请先运行 sign_all.sh)"
done

# ----[ Rootfs 模式: 本地 离线 / 制品仓库 下载 / Docker 在线 ]------------------
ROOTFS_BK="$ARTIFACT/oerv_rootfs_backup.tar.gz"
GITLAB_API="${GITLAB_API:-https://code.osssc.ac.cn/api/v4}"
GITLAB_PROJECT="${GITLAB_PROJECT:-}"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
PKG_NAME="oerv_rootfs_backup"
PKG_VERSION="1.0.0"
OFFLINE=false
[ "${1:-}" = "--docker" ] && OFFLINE=false && shift

# 优先级1: 本地已有离线备份文件
if [ -f "$ROOTFS_BK" ]; then
    OFFLINE=true
    _info "rootfs 模式: 本地离线备份 ($(du -h "$ROOTFS_BK" | cut -f1))"

# 优先级2: 从 GitLab Package Registry 下载 （需 GITLAB_PROJECT 与 GITLAB_TOKEN 环境变量）
elif [ -n "$GITLAB_PROJECT" ] && [ -n "$GITLAB_TOKEN" ]; then
    _info "尝试从 GitLab Package Registry 下载 rootfs..."
    _info "  → ${GITLAB_API}/projects/${GITLAB_PROJECT}/packages/generic/${PKG_NAME}/${PKG_VERSION}/oerv_rootfs_backup.tar.gz"
    if curl -fSL --progress-bar \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -o "$ROOTFS_BK" \
        "${GITLAB_API}/projects/${GITLAB_PROJECT}/packages/generic/${PKG_NAME}/${PKG_VERSION}/oerv_rootfs_backup.tar.gz"; then
        # 下载后做完整性验证
        if gzip -t "$ROOTFS_BK" 2>/dev/null; then
            OFFLINE=true
            _info "下载成功并验证完成 ($(du -h "$ROOTFS_BK" | cut -f1))"
        else
            _info "下载文件损坏, 删除并回退"
            rm -f "$ROOTFS_BK"
        fi
    else
        _info "下载失败 (检查环境变量 GITLAB_PROJECT / GITLAB_TOKEN 是否正确)"
        rm -f "$ROOTFS_BK"
    fi
fi

# 优先级3: Docker 在线安装
if $OFFLINE; then
    _info "rootfs 模式: 离线备份 ($(du -h "$ROOTFS_BK" | cut -f1))"
else
    _info "rootfs 模式: Docker (openeuler:24.03-lts-sp1)"
fi

# ----[ 清理 trap ]-----------------------------------------------------------
ESP_MP="" ROOT_MP="" LOOP=""
cleanup() {
    sudo umount "$ROOT_MP/boot/efi" 2>/dev/null || true
    sudo umount "$ROOT_MP/dev"       2>/dev/null || true
    sudo umount "$ROOT_MP/proc"      2>/dev/null || true
    sudo umount "$ROOT_MP/sys"       2>/dev/null || true
    sudo umount "$ESP_MP"            2>/dev/null || true
    sudo umount "$ROOT_MP"           2>/dev/null || true
    [ -n "$LOOP" ] && sudo losetup -d "$LOOP" 2>/dev/null || true
    sudo rm -rf "$ESP_MP" "$ROOT_MP" 2>/dev/null || true
    rm -f "$DISK_TMP"                2>/dev/null || true
}
trap cleanup EXIT

# =============================================================================
#  阶段 1: 创建磁盘 + 分区 + 格式化
# =============================================================================
_step "创建 12GB GPT 磁盘镜像 (ESP 512MB + rootfs 剩余)"
rm -f "$DISK_TMP"
qemu-img create -f raw "$DISK_TMP" 12G

sudo parted -s "$DISK_TMP" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 512MiB \
    set 1 esp on \
    mkpart primary ext4 512MiB 100%

LOOP=$(sudo losetup -f -P "$DISK_TMP" --show)
sleep 2

_step "格式化分区"
sudo mkfs.fat -F32 -n ESP   "${LOOP}p1"
sudo mkfs.ext4 -F  -L rootfs "${LOOP}p2"

ESP_MP="/tmp/esp_$$"
ROOT_MP="/tmp/root_$$"
mkdir -p "$ESP_MP" "$ROOT_MP"
sudo mount "${LOOP}p1" "$ESP_MP"
sudo mount "${LOOP}p2" "$ROOT_MP"

ROOT_UUID=$(sudo blkid -s UUID -o value "${LOOP}p2")
ESP_UUID=$(sudo blkid -s UUID -o value "${LOOP}p1")
_info "ESP UUID   = $ESP_UUID"
_info "Root UUID  = $ROOT_UUID"

# =============================================================================
#  阶段 2: 部署 EFI 文件到 ESP
# =============================================================================
_step "部署 Shim + MokManager + CSV 到 ESP"
sudo mkdir -p "$ESP_MP/EFI/BOOT" "$ESP_MP/EFI/openEuler"
sudo cp "$SHIM" "$ESP_MP/EFI/BOOT/BOOTRISCV64.EFI"            # fallback 入口
sudo cp "$SHIM" "$ESP_MP/EFI/openEuler/shimriscv64.efi"        # 主入口
sudo cp "$MM"   "$ESP_MP/EFI/openEuler/mmriscv64.efi"          # MokManager
sudo cp "$CSV"  "$ESP_MP/EFI/openEuler/BOOTRISCV64.CSV"       # shim 启动列表

_step "部署网络驱动到 ESP (Secure Boot 需已签名)"
# Hash2DxeCrypto → TcpDxe 的依赖 (gEfiHash2ServiceBindingProtocolGuid)
# TcpDxe         → HttpDxe 的依赖 (EFI_TCP4_PROTOCOL)
# HttpDxe        → Shim HTTP 远程验证所需
sudo cp "$DRV_HASH2" "$ESP_MP/EFI/BOOT/Hash2DxeCrypto.efi"
sudo cp "$DRV_TCP"   "$ESP_MP/EFI/BOOT/TcpDxe.efi"
sudo cp "$DRV_HTTP"  "$ESP_MP/EFI/BOOT/HttpDxe.efi"

_step "创建 startup.nsh (UEFI Shell 自动执行)"
sudo tee "$ESP_MP/EFI/BOOT/startup.nsh" > /dev/null << 'NSHEOF'
@echo -off
echo "=== RISC-V Secure Boot: Loading Network Drivers ==="
load fs0:\EFI\BOOT\Hash2DxeCrypto.efi
load fs0:\EFI\BOOT\TcpDxe.efi
load fs0:\EFI\BOOT\HttpDxe.efi
echo "=== Starting Shim ==="
fs0:\EFI\BOOT\BOOTRISCV64.EFI
echo "=== Shim exited ==="
NSHEOF
_info "ESP 部署完成"

# =============================================================================
#  阶段 3: 安装 OpenEuler RISC-V rootfs
# =============================================================================
_step "安装 rootfs"

if $OFFLINE; then
    _info "解压离线备份 (这可能需要几分钟)..."
    sudo tar -xzf "$ROOTFS_BK" -C "$ROOT_MP"
    sudo mkdir -p "$ROOT_MP"/{dev,proc,sys,run,var/log}
    _info "rootfs 离线解压完成"
else
    _info "Docker 安装 (需要网络)..."
    sudo docker run --privileged --rm \
        -e "ROOT_UUID=$ROOT_UUID" \
        -e "ESP_UUID=$ESP_UUID" \
        -v "$ROOT_MP":/mnt/rootfs \
        openeuler/openeuler:24.03-lts-sp1 \
        /bin/bash -c "$(cat <<'INNER'
set -e
dnf install -y util-linux > /dev/null
mkdir -p /mnt/rootfs/{dev,proc,sys,run,var/log}

# 挂载虚拟文件系统
grep -q " /mnt/rootfs/dev "  /proc/mounts 2>/dev/null || mount --bind /dev /mnt/rootfs/dev
[ -e /mnt/rootfs/proc/meminfo ]                || mount -t proc  proc  /mnt/rootfs/proc
[ -d /mnt/rootfs/sys/kernel  ]                 || mount -t sysfs sysfs /mnt/rootfs/sys
grep -q " /mnt/rootfs/run "  /proc/mounts 2>/dev/null || mount -t tmpfs tmpfs /mnt/rootfs/run

# 安装系统包
dnf install -y --installroot=/mnt/rootfs \
    --releasever=24.03 --forcearch=riscv64 \
    --repofrompath=openeuler,https://dl-cdn.openeuler.openatom.cn/openEuler-24.03-LTS/OS/riscv64/ \
    bash coreutils systemd dnf kernel mokutil \
    grub2-efi-riscv64 efibootmgr grub2-efi-riscv64-modules \
    --nogpgcheck

# 基础配置
cp /etc/resolv.conf /mnt/rootfs/etc/
cat > /mnt/rootfs/etc/fstab <<EOF
UUID=${ROOT_UUID} /         ext4    defaults,errors=remount-ro 0 1
UUID=${ESP_UUID}  /boot/efi vfat    umask=0077,nofail 0       0
proc              /proc     proc    defaults                   0 0
sysfs             /sys      sysfs   defaults                   0 0
devtmpfs          /dev      devtmpfs defaults                  0 0
tmpfs             /run      tmpfs   defaults                   0 0
EOF
echo "openeuler-riscv" > /mnt/rootfs/etc/hostname
sed -i 's|^root:[^:]*:|root::|' /mnt/rootfs/etc/shadow
mkdir -p /mnt/rootfs/boot/grub2 /mnt/rootfs/boot/efi
INNER
)"
    _info "Docker 安装完成"
fi

# =============================================================================
#  阶段 4: 构建 GRUB (RISC-V 原生, 通过 qemu-user)
# =============================================================================
_step "构建 GRUB EFI 二进制"

# 必须用 RISC-V 原生 grub2-mkimage (qemu-riscv64-static 运行)
# 宿主机 x86_64 版本会产生 RISC-V relocation overflow
command -v qemu-riscv64-static >/dev/null 2>&1 || {
    sudo apt-get update && sudo apt-get install -y qemu-user-static
}

GRUB_MOD=$(ls -d "$ROOT_MP"/usr/lib*/grub/riscv64-efi 2>/dev/null | head -1)
[ -n "$GRUB_MOD" ] || _die "未找到 riscv64-efi GRUB 模块"

GRUB_BIN="$ROOT_MP/usr/bin/grub2-mkimage"
[ -f "$GRUB_BIN" ] || GRUB_BIN="$ROOT_MP/usr/bin/grub-mkimage"
[ -f "$GRUB_BIN" ] || _die "未找到 grub2-mkimage"

# SBAT 数据 (Secure Boot Advanced Targeting)
cat > /tmp/grub_sbat.csv << 'SBAT_EOF'
sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
grub,4,Free Software Foundation,grub,2.12,https://www.gnu.org/software/grub/
grub.openeuler,1,openEuler,grub2,2.12,https://repo.openeuler.org
SBAT_EOF

_info "运行 qemu-riscv64-static grub2-mkimage..."
export QEMU_LD_PREFIX="$ROOT_MP"
qemu-riscv64-static "$GRUB_BIN" \
    -d "$GRUB_MOD" \
    -o "$ESP_MP/EFI/openEuler/grubriscv64.efi" \
    --sbat /tmp/grub_sbat.csv \
    -O riscv64-efi \
    -p /EFI/openEuler \
    part_gpt part_msdos fat ext2 normal \
    configfile linux search search_fs_uuid \
    search_label echo test cat ls loadenv \
    minicmd boot chain reboot halt gzio fdt 2>&1
_info "GRUB 构建完成"

# =============================================================================
#  阶段 5: 生成 DTB + Grub 配置
# =============================================================================
_step "生成 QEMU virt Device Tree Blob"
# 使用 -bios none 跳过固件, dumpdtb 在初始化失败前就能输出 DTB
DTB="/tmp/riscv-virt-dtb-$$.dtb"
touch "$DTB"
qemu-system-riscv64 -bios none \
    -machine "virt,dumpdtb=${DTB}" \
    -display none -m 256M -nographic 2>&1
[ -f "$DTB" ] && [ -s "$DTB" ] || _die "DTB 生成失败"
sudo cp "$DTB" "$ROOT_MP/boot/riscv-virt.dtb"
rm -f "$DTB"
_info "DTB → /boot/riscv-virt.dtb"

_step "创建 grub.cfg"
for f in "$ROOT_MP"/boot/vmlinuz-*; do
	[ -f "$f" ] && KVER=$(basename "$f" | sed 's|^vmlinuz-||') && break
done
[ -n "$KVER" ] || _die "未找到内核 (vmlinuz)"

# 注意: RISC-V 下 GRUB lockdown 会阻止 devicetree 命令
# 但 UEFI 固件会自动将 DTB 放入 Configuration Table, 内核可直接读取
sudo tee "$ESP_MP/EFI/openEuler/grub.cfg" > /dev/null << GRUBCFGEOF
set default=0
set timeout=10
search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
menuentry "openEuler RISC-V" {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux  /boot/vmlinuz-${KVER} root=UUID=${ROOT_UUID} rw earlycon=sbi console=ttyS0,115200n8
    initrd /boot/initramfs-${KVER}.img
}
GRUBCFGEOF
sudo cp "$ESP_MP/EFI/openEuler/grub.cfg" "$ROOT_MP/boot/grub2/grub.cfg"
_info "grub.cfg 已生成 (内核: ${KVER})"

# =============================================================================
#  阶段 6: 签名 GRUB + 内核
# =============================================================================
_step "签名 GRUB EFI"
# 顺序: fix_reloc → sbsign → sbverify (fix_reloc 会破坏已有签名)
command -v sbsign >/dev/null 2>&1 || {
    sudo apt-get update && sudo apt-get install -y sbsigntool
}

GRUB_EFI="$ESP_MP/EFI/openEuler/grubriscv64.efi"
[ -f "$GRUB_EFI" ] || _die "GRUB EFI 文件不存在"

if [ -f "$FIX_RELOC" ]; then
    python3 "$FIX_RELOC" "$GRUB_EFI"
    _info "GRUB fix_reloc 完成"
fi
sbsign --key "$DB_KEY" --cert "$DB_CRT" --output "$GRUB_EFI" "$GRUB_EFI"
sbverify --cert "$DB_CRT" "$GRUB_EFI" | grep -q 'Signature verification OK' \
    || _die "GRUB 签名验证失败"
sudo cp "$GRUB_EFI" "$ESP_MP/EFI/BOOT/grubriscv64.efi"
_info "GRUB 签名完成"

_step "签名 Linux 内核"
# 发行版内核无预签名, Secure Boot 下 GRUB shim_verify() 会拒绝未签名内核
KERNEL="$ROOT_MP/boot/vmlinuz-${KVER}"
sudo sbsign --key "$DB_KEY" --cert "$DB_CRT" --output "$KERNEL" "$KERNEL"
sbverify --cert "$DB_CRT" "$KERNEL" \
    | grep -q 'Signature verification OK' || _die "内核签名失败"
_info "内核签名完成: vmlinuz-${KVER}"

# =============================================================================
#  阶段 7: 完成
# =============================================================================
_step "完成 — 验证 ESP 文件列表"
find "$ESP_MP" -type f | sort
mv -f "$DISK_TMP" "$DISK"
echo ""
printf '%s============================================%s\n' "$BLUE" "$WHITE"
printf '%s  镜像构建成功!%s\n' "$BLUE" "$WHITE"
printf '%s  位置: %s%s\n' "$BLUE" "$DISK" "$WHITE"
printf '%s  大小: %s%s\n' "$BLUE" "$(du -h "$DISK" | cut -f1)" "$WHITE"
printf '%s============================================%s\n' "$BLUE" "$WHITE"
