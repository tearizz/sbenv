#!/bin/bash
set -e
# =============================================================================
# build-x86ubuntu.sh — x86_64 Ubuntu Secure Boot 磁盘镜像构建
#
# 前置依赖: sign-x86.sh (shim 已签名)
# 前置文件: artifact/kernel/vmlinuz-* 和 artifact/kernel/initrd.img-*
# 用法:      sudo ./script/image/build-x86ubuntu.sh
# =============================================================================

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
WS=$(dirname "$(dirname "$SELF_DIR")")
ARTIFACT="$WS/artifact"

SHIM="$ARTIFACT/shim/shimx64.efi"
MM="$ARTIFACT/shim/mmx64.efi"
CSV="$ARTIFACT/shim/BOOTX64.CSV"
DB_KEY="$ARTIFACT/keys/DB.key"
DB_CRT="$ARTIFACT/keys/DB.crt"

DISK="$ARTIFACT/images/x86_ubuntu.img"
DISK_TMP="${DISK}.tmp.$$"

# ----[ pre-check ]-----------------------------------------------------------
for f in "$SHIM" "$MM" "$DB_KEY" "$DB_CRT"; do
    [ -f "$f" ] || { echo "[ERROR] missing: $f (run sign-x86.sh first)"; exit 1; }
done

KERNEL=$(ls "$ARTIFACT/kernel/vmlinuz-"* 2>/dev/null | head -1)
INITRD=$(ls "$ARTIFACT/kernel/initrd.img-"* 2>/dev/null | head -1)
[ -f "$KERNEL" ] || { echo "[ERROR] missing kernel in artifact/kernel/"; exit 1; }
[ -f "$INITRD" ] || { echo "[ERROR] missing initrd in artifact/kernel/"; exit 1; }
KVER=$(basename "$KERNEL" | sed 's|^vmlinuz-||')
echo "  kernel version: $KVER"

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
echo "[1/6] Creating 12GB GPT disk (ESP 512MB + rootfs)"

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

# =============================================================================
#  2. Deploy EFI files to ESP
# =============================================================================
echo "[2/6] Deploying Shim + MokManager to ESP"

sudo mkdir -p "$ESP_MP/EFI/BOOT" "$ESP_MP/EFI/ubuntu"
sudo cp "$SHIM" "$ESP_MP/EFI/BOOT/BOOTX64.EFI"
sudo cp "$SHIM" "$ESP_MP/EFI/ubuntu/shimx64.efi"
sudo cp "$MM"   "$ESP_MP/EFI/ubuntu/mmx64.efi"

if [ -f "$CSV" ]; then
    sudo cp "$CSV" "$ESP_MP/EFI/ubuntu/BOOTX64.CSV"
else
    echo "shimx64.efi,Ubuntu,,This is the boot entry for Ubuntu" \
        | iconv -t UCS-2LE | sudo tee "$ESP_MP/EFI/ubuntu/BOOTX64.CSV" > /dev/null
    echo "  BOOTX64.CSV generated"
fi

# =============================================================================
#  3. Install Ubuntu rootfs via debootstrap
# =============================================================================
echo "[3/6] Installing Ubuntu rootfs via debootstrap (this may take a few minutes)..."

command -v debootstrap >/dev/null 2>&1 || {
    sudo apt-get update && sudo apt-get install -y debootstrap
}

sudo debootstrap --arch amd64 \
    --include=grub-common,grub2-common,grub-efi-amd64,grub-efi-amd64-bin \
    jammy "$ROOT_MP" http://archive.ubuntu.com/ubuntu > /dev/null 2>&1

echo "  Copying kernel + initrd..."
sudo cp "$KERNEL" "$ROOT_MP/boot/"
sudo cp "$INITRD" "$ROOT_MP/boot/"

if [ -d "/lib/modules/$KVER" ]; then
    sudo mkdir -p "$ROOT_MP/lib/modules"
    sudo cp -r "/lib/modules/$KVER" "$ROOT_MP/lib/modules/"
    echo "  kernel modules copied"
else
    echo "  [WARN] kernel modules not found on host, VM may lack drivers"
fi

# =============================================================================
#  4. Configure system and build GRUB via chroot
# =============================================================================
echo "[4/6] Configuring system and building GRUB"

ROOT_UUID=$(sudo blkid -s UUID -o value "${LOOP}p2")
ESP_UUID=$(sudo blkid -s UUID -o value "${LOOP}p1")
echo "  ESP  UUID = $ESP_UUID"
echo "  Root UUID = $ROOT_UUID"

sudo tee "$ROOT_MP/etc/fstab" > /dev/null <<EOF
UUID=$ROOT_UUID /               ext4    defaults,errors=remount-ro 0 1
UUID=$ESP_UUID  /boot/efi       vfat    umask=0077,nofail 0       0
proc            /proc           proc    defaults        0       0
sysfs           /sys            sysfs   defaults        0       0
devtmpfs        /dev            devtmpfs defaults       0       0
tmpfs           /run            tmpfs   defaults        0       0
EOF

echo "ubuntu-x86" | sudo tee "$ROOT_MP/etc/hostname" > /dev/null
sudo tee "$ROOT_MP/etc/hosts" > /dev/null <<EOF
127.0.0.1   localhost
127.0.1.1   ubuntu-x86
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

sudo tee "$ROOT_MP/etc/default/grub" > /dev/null <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=10
GRUB_DISTRIBUTOR="Ubuntu"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="console=ttyS0,115200n8 console=tty0 rw"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_DISABLE_OS_PROBER=true
GRUB_USE_LINUXEFI=true
EOF

sudo mkdir -p "$ROOT_MP/boot/efi"
sudo mount --bind /dev  "$ROOT_MP/dev"
sudo mount --bind /proc "$ROOT_MP/proc"
sudo mount --bind /sys  "$ROOT_MP/sys"
sudo mount --bind "$ESP_MP" "$ROOT_MP/boot/efi"

sudo env ROOT_UUID="$ROOT_UUID" ESP_UUID="$ESP_UUID" \
    chroot "$ROOT_MP" /bin/bash <<'CHROOT'
set -e
export DEBIAN_FRONTEND=noninteractive

echo "root:password" | chpasswd

cat > /tmp/grub_sbat.csv << 'SBAT_EOF'
sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
grub,4,Free Software Foundation,grub,2.06,https://www.gnu.org/software/grub/
grub.ubuntu,1,Ubuntu,grub2,2.06,https://packages.ubuntu.com/grub2
SBAT_EOF

echo "  Building GRUB..."

# Embedded early config: search ESP by UUID so GRUB always finds grub.cfg
printf 'search --no-floppy --fs-uuid %s --set=root\nset prefix=($root)/EFI/ubuntu\nconfigfile $prefix/grub.cfg\n' \
    "$ESP_UUID" > /tmp/grub_early.cfg

grub-mkimage \
    -o /boot/efi/EFI/ubuntu/grubx64.efi \
    --sbat /tmp/grub_sbat.csv \
    -c /tmp/grub_early.cfg \
    -O x86_64-efi \
    -p /EFI/ubuntu \
    part_gpt part_msdos fat ext2 normal \
    configfile linux search search_fs_uuid \
    search_label echo test cat ls loadenv \
    minicmd boot chain reboot halt gzio gfxterm \
    gfxmenu all_video video video_fb \
    gettext true sleep linuxefi

grub-mkconfig -o /boot/grub/grub.cfg

# Fix: grub-probe sees host loop device, replace with correct UUID
sed -i "s|root=/dev/loop[0-9]*p[0-9]*|root=UUID=${ROOT_UUID}|g" /boot/grub/grub.cfg

[ -f /boot/efi/EFI/ubuntu/grubx64.efi ] || { echo "[ERROR] GRUB build failed"; exit 1; }
[ -f /boot/grub/grub.cfg ]             || { echo "[ERROR] grub.cfg generation failed"; exit 1; }

apt-get install -y mokutil > /dev/null 2>&1
echo "  GRUB installed successfully"
CHROOT

# Copy grub.cfg to ESP — both /boot/grub/ and /EFI/ubuntu/ for robustness
if [ -f "$ROOT_MP/boot/grub/grub.cfg" ]; then
    sudo mkdir -p "$ESP_MP/boot/grub" "$ESP_MP/EFI/ubuntu"
    sudo cp "$ROOT_MP/boot/grub/grub.cfg" "$ESP_MP/boot/grub/"
    sudo cp "$ROOT_MP/boot/grub/grub.cfg" "$ESP_MP/EFI/ubuntu/grub.cfg"
fi

# =============================================================================
#  5. Sign GRUB + kernel
# =============================================================================
echo "[5/6] Signing GRUB and kernel"

command -v sbsign >/dev/null 2>&1 || {
    sudo apt-get update && sudo apt-get install -y sbsigntool
}

GRUB_EFI="$ESP_MP/EFI/ubuntu/grubx64.efi"
[ -f "$GRUB_EFI" ] || { echo "[ERROR] GRUB EFI not found: $GRUB_EFI"; exit 1; }

sbsign --key "$DB_KEY" --cert "$DB_CRT" --output "$GRUB_EFI" "$GRUB_EFI"
sbverify --cert "$DB_CRT" "$GRUB_EFI" > /dev/null 2>&1 \
    || { echo "[ERROR] GRUB signature verification failed"; exit 1; }
echo "  GRUB signed"

sudo cp "$GRUB_EFI" "$ESP_MP/EFI/BOOT/grubx64.efi"

KERNEL_BIN="$ROOT_MP/boot/vmlinuz-$KVER"
[ -f "$KERNEL_BIN" ] || { echo "[ERROR] kernel not found: $KERNEL_BIN"; exit 1; }

sudo sbsign --key "$DB_KEY" --cert "$DB_CRT" --output "$KERNEL_BIN" "$KERNEL_BIN"
sbverify --cert "$DB_CRT" "$KERNEL_BIN" > /dev/null 2>&1 \
    || { echo "[ERROR] kernel signature verification failed"; exit 1; }
echo "  kernel signed: vmlinuz-$KVER"

# =============================================================================
#  6. Finish
# =============================================================================
echo "[6/6] Verifying ESP contents"
find "$ESP_MP" -type f | sort

mv -f "$DISK_TMP" "$DISK"
echo ""
echo "  Image built: $DISK ($(du -h "$DISK" | cut -f1))"
