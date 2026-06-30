#!/bin/bash
set -e
# =============================================================================
# build-x86oe.sh — x86_64 openEuler Secure Boot 磁盘镜像构建
#
# 前置依赖: sign-x86.sh (shim 已签名)
# 用法:      sudo ./script/image/build-x86oe.sh
# =============================================================================

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
WS=$(dirname "$(dirname "$SELF_DIR")")
ARTIFACT="$WS/artifact"

SHIM="$ARTIFACT/shim/shimx64.efi"
MM="$ARTIFACT/shim/mmx64.efi"
CSV="$ARTIFACT/shim/BOOTX64.CSV"
DB_KEY="$ARTIFACT/keys/DB.key"
DB_CRT="$ARTIFACT/keys/DB.crt"

DISK="$ARTIFACT/images/x86_openEuler.img"
DISK_TMP="${DISK}.tmp.$$"

# ----[ pre-check ]-----------------------------------------------------------
for f in "$SHIM" "$MM" "$DB_KEY" "$DB_CRT"; do
    [ -f "$f" ] || { echo "[ERROR] missing: $f (run sign-x86.sh first)"; exit 1; }
done

# ----[ cleanup ]-------------------------------------------------------------
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
#  1. Create GPT disk
# =============================================================================
echo "[1/5] Creating 12GB GPT disk (ESP 512MB + rootfs)"

rm -f "$DISK_TMP"
qemu-img create -f raw "$DISK_TMP" 12G

sudo parted -s "$DISK_TMP" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 512MiB \
    set 1 esp on \
    mkpart primary ext4 512MiB 100%

LOOP=$(sudo losetup -f -P "$DISK_TMP" --show)
sleep 2

sudo mkfs.fat -F32 -n ESP   "${LOOP}p1"
sudo mkfs.ext4 -F  -L rootfs "${LOOP}p2"

ESP_MP="/tmp/esp_$$"
ROOT_MP="/tmp/root_$$"
mkdir -p "$ESP_MP" "$ROOT_MP"
sudo mount "${LOOP}p1" "$ESP_MP"
sudo mount "${LOOP}p2" "$ROOT_MP"

ROOT_UUID=$(sudo blkid -s UUID -o value "${LOOP}p2")
ESP_UUID=$(sudo blkid -s UUID -o value "${LOOP}p1")
echo "  ESP  UUID = $ESP_UUID"
echo "  Root UUID = $ROOT_UUID"

# =============================================================================
#  2. Deploy EFI files to ESP
# =============================================================================
echo "[2/5] Deploying Shim + MokManager to ESP"

sudo mkdir -p "$ESP_MP/EFI/BOOT" "$ESP_MP/EFI/openEuler"
sudo cp "$SHIM" "$ESP_MP/EFI/BOOT/BOOTX64.EFI"
sudo cp "$SHIM" "$ESP_MP/EFI/openEuler/shimx64.efi"
sudo cp "$MM"   "$ESP_MP/EFI/openEuler/mmx64.efi"

if [ -f "$CSV" ]; then
    sudo cp "$CSV" "$ESP_MP/EFI/openEuler/BOOTX64.CSV"
else
    echo "shimx64.efi,openEuler,,This is the boot entry for openEuler" \
        | iconv -t UCS-2LE | sudo tee "$ESP_MP/EFI/openEuler/BOOTX64.CSV" > /dev/null
    echo "  BOOTX64.CSV generated"
fi

# ----[ Rootfs 来源: 本地 离线 / 制品仓库 下载 / Docker 在线 ]------------------
ROOTFS_BK="$ARTIFACT/oex86_rootfs_backup.tar.gz"
GITLAB_API="${GITLAB_API:-https://code.osssc.ac.cn/api/v4}"
GITLAB_PROJECT="${GITLAB_PROJECT:-}"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
PKG_NAME="oex86_rootfs_backup"
PKG_VERSION="1.0.0"
OFFLINE=false

# 优先级1: 本地已有离线备份文件
if [ -f "$ROOTFS_BK" ] && gzip -t "$ROOTFS_BK" 2>/dev/null; then
    OFFLINE=true
    echo "[3/5] Extracting rootfs from local backup ($(du -h "$ROOTFS_BK" | cut -f1))..."
    sudo tar -xzf "$ROOTFS_BK" -C "$ROOT_MP"
    sudo mkdir -p "$ROOT_MP"/{dev,proc,sys,run,boot/efi}
    echo "  Extraction complete"

# 优先级2: 从 GitLab Package Registry 下载 (需 GITLAB_PROJECT 与 GITLAB_TOKEN 环境变量)
elif [ -n "$GITLAB_PROJECT" ] && [ -n "$GITLAB_TOKEN" ]; then
    echo "[3/5] Downloading rootfs from GitLab Package Registry..."
    echo "  → ${GITLAB_API}/projects/${GITLAB_PROJECT}/packages/generic/${PKG_NAME}/${PKG_VERSION}/oex86_rootfs_backup.tar.gz"
    if curl -fSL --progress-bar \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -o "$ROOTFS_BK" \
        "${GITLAB_API}/projects/${GITLAB_PROJECT}/packages/generic/${PKG_NAME}/${PKG_VERSION}/oex86_rootfs_backup.tar.gz"; then
        if gzip -t "$ROOTFS_BK" 2>/dev/null; then
            OFFLINE=true
            echo "  Download OK ($(du -h "$ROOTFS_BK" | cut -f1))"
            echo "  Extracting..."
            sudo tar -xzf "$ROOTFS_BK" -C "$ROOT_MP"
            sudo mkdir -p "$ROOT_MP"/{dev,proc,sys,run,boot/efi}
            echo "  Extraction complete"
        else
            echo "  Download corrupted, falling back to Docker"
            rm -f "$ROOTFS_BK"
        fi
    else
        echo "  Download failed (check GITLAB_PROJECT / GITLAB_TOKEN)"
        [ -f "$ROOTFS_BK" ] && rm -f "$ROOTFS_BK"
    fi
fi

# 优先级3: Docker 在线安装
if ! $OFFLINE; then
    echo "[3/5] Installing rootfs via Docker (this may take several minutes)..."

    sudo docker pull hub.oepkgs.net/openeuler/openeuler:24.03-lts

    sudo docker run --privileged --rm \
        -e "ROOT_UUID=$ROOT_UUID" \
        -e "ESP_UUID=$ESP_UUID" \
        -v "$ROOT_MP":/mnt/rootfs \
        -v "$ESP_MP":/mnt/esp \
        hub.oepkgs.net/openeuler/openeuler:24.03-lts \
        /bin/bash -c "$(cat <<'INNER'
set -e
dnf install -y -q util-linux

# Mount /proc /sys /dev BEFORE dnf — RPM post-install scripts
# (dracut, systemd, etc.) need them to generate a working initramfs
mkdir -p /mnt/rootfs/{dev,proc,sys,run}
mount --bind /dev  /mnt/rootfs/dev
mount -t proc proc  /mnt/rootfs/proc
mount -t sysfs sysfs /mnt/rootfs/sys

echo "  Installing base system via dnf..."
dnf install -y -q --installroot=/mnt/rootfs \
    --releasever=24.03 \
    --repofrompath=openeuler,http://repo.openeuler.org/openEuler-24.03-LTS/OS/x86_64/ \
    bash coreutils systemd dnf kernel mokutil \
    grub2-efi-x64 efibootmgr grub2-efi-x64-modules \
    --nogpgcheck

cp /etc/resolv.conf /mnt/rootfs/etc/
mount --bind /mnt/esp /mnt/rootfs/boot/efi

echo "  Configuring system in chroot..."

# ROOT_UUID & ESP_UUID are Docker env vars, inherited by chroot bash
chroot /mnt/rootfs /bin/bash <<'CHROOT'
set -e

cat > /etc/fstab <<EOF
UUID=$ROOT_UUID /               ext4    defaults,errors=remount-ro 0 1
UUID=$ESP_UUID  /boot/efi       vfat    umask=0077,nofail 0       0
proc            /proc           proc    defaults        0       0
sysfs           /sys            sysfs   defaults        0       0
devtmpfs        /dev            devtmpfs defaults       0       0
tmpfs           /run            tmpfs   defaults        0       0
EOF

echo "openeuler-x86" > /etc/hostname
echo "root:password" | chpasswd

cat > /etc/default/grub << 'GRUB_EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=10
GRUB_DISTRIBUTOR="openEuler"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="rw console=tty0 console=ttyS0,115200n8"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_DISABLE_OS_PROBER=true
GRUB_USE_LINUXEFI=true
GRUB_EOF

cat > /tmp/grub_sbat.csv << 'SBAT_EOF'
sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
grub,4,Free Software Foundation,grub,2.12,https://www.gnu.org/software/grub/
grub.openeuler,1,openEuler,grub2,2.12,https://repo.openeuler.org
SBAT_EOF

echo "  Building GRUB..."

# Embedded early config: search ESP by UUID so GRUB always finds grub.cfg
printf 'search --no-floppy --fs-uuid %s --set=root\nset prefix=($root)/EFI/openEuler\nconfigfile $prefix/grub.cfg\n' \
    "$ESP_UUID" > /tmp/grub_early.cfg

grub2-mkimage \
    -o /boot/efi/EFI/openEuler/grubx64.efi \
    --sbat /tmp/grub_sbat.csv \
    -c /tmp/grub_early.cfg \
    -O x86_64-efi \
    -p /EFI/openEuler \
    part_gpt part_msdos fat ext2 normal \
    configfile linux search search_fs_uuid \
    search_label echo test cat ls loadenv \
    minicmd boot chain reboot halt gzio linuxefi

grub2-mkconfig -o /boot/efi/EFI/openEuler/grub.cfg

# Fix: grub-probe sees host loop device, replace with correct UUID
sed -i "s|root=/dev/loop[0-9]*p[0-9]*|root=UUID=${ROOT_UUID}|g" \
    /boot/efi/EFI/openEuler/grub.cfg

cp /boot/efi/EFI/openEuler/grub.cfg /boot/grub2/grub.cfg

[ -f /boot/efi/EFI/openEuler/grubx64.efi ] || {
    echo "[ERROR] GRUB build failed"; exit 1;
}
echo "  GRUB installed successfully"
CHROOT

umount /mnt/rootfs/dev
umount /mnt/rootfs/proc
umount /mnt/rootfs/sys
umount /mnt/rootfs/boot/efi
echo "  Docker container finished"
INNER
)"
fi

# =============================================================================
#  3a. Post-install: fix UUIDs and rebuild GRUB (offline mode)
# =============================================================================
if $OFFLINE; then
    echo "  Fixing fstab and rebuilding GRUB for new UUIDs..."

    # Update fstab with new disk UUIDs
    sudo sed -i "s|^UUID=[^ ]* / |UUID=$ROOT_UUID / |" "$ROOT_MP/etc/fstab"
    sudo sed -i "s|^UUID=[^ ]* /boot/efi |UUID=$ESP_UUID /boot/efi |" "$ROOT_MP/etc/fstab"

    # Mount virt filesystems + ESP into offline rootfs
    sudo mount --bind /dev  "$ROOT_MP/dev"
    sudo mount -t proc proc  "$ROOT_MP/proc"
    sudo mount -t sysfs sysfs "$ROOT_MP/sys"
    sudo mount --bind "$ESP_MP" "$ROOT_MP/boot/efi"

    # Rebuild initramfs with ALL drivers (--no-hostonly).
    # Without this, dracut detects host hardware (NVMe etc.) and omits
    # the IDE/SATA drivers that QEMU's emulated disk controller needs.
    KVER=$(ls "$ROOT_MP/boot/vmlinuz-"* 2>/dev/null | head -1 | sed 's|.*/vmlinuz-||')
    if [ -n "$KVER" ]; then
        sudo chroot "$ROOT_MP" dracut -f --no-hostonly \
            --add-drivers "ata_piix ahci sd_mod ext4" \
            "/boot/initramfs-$KVER.img" "$KVER"
        echo "  initramfs rebuilt (no-hostonly) for $KVER"
    fi

    # Rebuild GRUB with new UUIDs
    sudo env "ROOT_UUID=$ROOT_UUID" "ESP_UUID=$ESP_UUID" \
        chroot "$ROOT_MP" /bin/bash <<'OFFCHROOT'
set -e

cat > /tmp/grub_sbat.csv << 'SBAT_EOF'
sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
grub,4,Free Software Foundation,grub,2.12,https://www.gnu.org/software/grub/
grub.openeuler,1,openEuler,grub2,2.12,https://repo.openeuler.org
SBAT_EOF

# Embedded early config: search ESP by UUID so GRUB always finds grub.cfg
printf 'search --no-floppy --fs-uuid %s --set=root\nset prefix=($root)/EFI/openEuler\nconfigfile $prefix/grub.cfg\n' \
    "$ESP_UUID" > /tmp/grub_early.cfg

grub2-mkimage \
    -o /boot/efi/EFI/openEuler/grubx64.efi \
    --sbat /tmp/grub_sbat.csv \
    -c /tmp/grub_early.cfg \
    -O x86_64-efi \
    -p /EFI/openEuler \
    part_gpt part_msdos fat ext2 normal \
    configfile linux search search_fs_uuid \
    search_label echo test cat ls loadenv \
    minicmd boot chain reboot halt gzio linuxefi

grub2-mkconfig -o /boot/efi/EFI/openEuler/grub.cfg

sed -i "s|root=/dev/loop[0-9]*p[0-9]*|root=UUID=${ROOT_UUID}|g" \
    /boot/efi/EFI/openEuler/grub.cfg

cp /boot/efi/EFI/openEuler/grub.cfg /boot/grub2/grub.cfg

[ -f /boot/efi/EFI/openEuler/grubx64.efi ] || {
    echo "[ERROR] GRUB build failed"; exit 1;
}
echo "  GRUB rebuilt successfully"
OFFCHROOT

    sudo umount "$ROOT_MP/boot/efi"
    sudo umount "$ROOT_MP/sys"
    sudo umount "$ROOT_MP/proc"
    sudo umount "$ROOT_MP/dev"
fi

# =============================================================================
#  4. Sign GRUB + kernel
# =============================================================================
echo "[4/5] Signing GRUB and kernel"

command -v sbsign >/dev/null 2>&1 || {
    sudo apt-get update && sudo apt-get install -y sbsigntool
}

GRUB_EFI="$ESP_MP/EFI/openEuler/grubx64.efi"
[ -f "$GRUB_EFI" ] || { echo "[ERROR] GRUB EFI not found: $GRUB_EFI"; exit 1; }

sbsign --key "$DB_KEY" --cert "$DB_CRT" --output "$GRUB_EFI" "$GRUB_EFI"
sbverify --cert "$DB_CRT" "$GRUB_EFI" > /dev/null 2>&1 \
    || { echo "[ERROR] GRUB signature verification failed"; exit 1; }
echo "  GRUB signed"

sudo cp "$GRUB_EFI" "$ESP_MP/EFI/BOOT/grubx64.efi"

KERNEL=$(ls "$ROOT_MP"/boot/vmlinuz-* 2>/dev/null | head -1)
[ -f "$KERNEL" ] || { echo "[ERROR] kernel not found in rootfs"; exit 1; }

sudo sbsign --key "$DB_KEY" --cert "$DB_CRT" --output "$KERNEL" "$KERNEL"
sbverify --cert "$DB_CRT" "$KERNEL" > /dev/null 2>&1 \
    || { echo "[ERROR] kernel signature verification failed"; exit 1; }

KVER=$(basename "$KERNEL" | sed 's|^vmlinuz-||')
echo "  kernel signed: vmlinuz-$KVER"

# =============================================================================
#  5. Finish
# =============================================================================
echo "[5/5] Verifying ESP contents"
find "$ESP_MP" -type f | sort

mv -f "$DISK_TMP" "$DISK"
echo ""
echo "  Image built: $DISK ($(du -h "$DISK" | cut -f1))"
