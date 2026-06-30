#!/bin/bash
set -e
# boot.sh — QEMU UEFI Secure Boot launcher (RISC-V & x86_64)
#
# All firmware is Secure Boot enabled by default.
#
# Usage:
#   sudo ./boot.sh --arch rv  --os openEuler
#   sudo ./boot.sh --arch x86 --os openEuler
#   sudo ./boot.sh --arch x86 --os ubuntu

# ----[ paths ]---------------------------------------------------------------
artifact_path="$PWD/artifact"

declare -A DISK_IMAGE=(
    [x86:ubuntu]="$artifact_path/images/x86_ubuntu.img"
    [x86:openEuler]="$artifact_path/images/x86_openEuler.img"
    [rv:openEuler]="$artifact_path/images/RiscV_OpenEuler.img"
)

declare -A OVMF_CODE=(
    [x86]="$artifact_path/ovmf/x86code.fd"
    [rv]="$artifact_path/ovmf/rvcode.fd"
)

declare -A OVMF_VARS=(
    [x86]="$artifact_path/ovmf/x86vars.fd"
    [rv]="$artifact_path/ovmf/rvvars.fd"
)

# ----[ usage ]---------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 --arch <rv|x86> --os <openEuler|ubuntu>

  -a, --arch      Target: rv (RISC-V) or x86 (x86_64)
  -k, --os    Guest OS: openEuler or ubuntu

Examples:
  sudo ./boot.sh --arch rv  --os openEuler
  sudo ./boot.sh --arch x86 --os openEuler
  sudo ./boot.sh --arch x86 --os ubuntu
EOF
    exit 0
}

# ----[ parse args ]----------------------------------------------------------
SHORT_OPTS="ha:o:"
LONG_OPTS="help,arch:,os:"

ARGS=$(getopt -o "$SHORT_OPTS" -l "$LONG_OPTS" -n "$0" -- "$@")
[ $? -ne 0 ] && exit 1
eval set -- "$ARGS"

ARCH="" OS_NAME=""

while true; do
    case "$1" in
        -h|--help) usage ;;
        -a|--arch)   ARCH="$2";   shift 2 ;;
        -k|--os) OS_NAME="$2"; shift 2 ;;
        --) shift; break ;;
        *) echo "[ERROR] internal error"; exit 1 ;;
    esac
done

# ----[ validate ]------------------------------------------------------------
if [ -z "$ARCH" ] || { [ "$ARCH" != "rv" ] && [ "$ARCH" != "x86" ]; }; then
    echo "[ERROR] --arch must be 'rv' or 'x86'"; usage
fi
if [ -z "$OS_NAME" ] || { [ "$OS_NAME" != "openEuler" ] && [ "$OS_NAME" != "ubuntu" ]; }; then
    echo "[ERROR] --os must be 'openEuler' or 'ubuntu'"; usage
fi
if [ "$ARCH" = "rv" ] && [ "$OS_NAME" = "ubuntu" ]; then
    echo "[ERROR] rv + ubuntu not supported yet"; exit 1
fi

# ----[ check files ]---------------------------------------------------------
CODE="${OVMF_CODE[$ARCH]}"
VARS="${OVMF_VARS[$ARCH]}"
DISK="${DISK_IMAGE[$ARCH:$OS_NAME]}"

[ -f "$CODE" ] || { echo "[ERROR] firmware not found: $CODE"; exit 1; }
[ -f "$VARS" ] || { echo "[ERROR] firmware not found: $VARS"; exit 1; }
[ -f "$DISK" ] || { echo "[ERROR] disk image not found: $DISK"; exit 1; }

# ----[ build QEMU command ]--------------------------------------------------
QEMU=(sudo -S)

if [ "$ARCH" = "x86" ]; then
    QEMU+=(qemu-system-x86_64)
    QEMU+=(-machine q35,smm=on)
    QEMU+=(-cpu host --enable-kvm)
    QEMU+=(-vga std)
    QEMU+=(-device virtio-rng-pci)
    QEMU+=(-nodefaults)
    QEMU+=(-boot menu=on,splash-time=0)
    QEMU+=(-smp 4 -m 4G)
    QEMU+=(-no-reboot -nographic)
    QEMU+=(-serial mon:stdio)
    QEMU+=(-netdev user,id=net0,hostfwd=tcp::12055-:22)
    QEMU+=(-device virtio-net-pci,netdev=net0)
    QEMU+=(-drive if=pflash,format=raw,readonly=on,file="$CODE")
    QEMU+=(-drive if=pflash,format=raw,file="$VARS")
    QEMU+=(-drive if=ide,format=raw,file="$DISK")
else
    QEMU+=(qemu-system-riscv64)
    QEMU+=(-nographic -machine virt,pflash0=pflash0,pflash1=pflash1,acpi=off)
    QEMU+=(-cpu rva23s64,sv39=on,zkr=true)
    QEMU+=(-smp 1 -m 4G)
    QEMU+=(-object rng-random,filename=/dev/urandom,id=rng0)
    QEMU+=(-device virtio-vga)
    QEMU+=(-device virtio-rng-device,rng=rng0)
    QEMU+=(-device virtio-blk-device,drive=disk0)
    QEMU+=(-device virtio-net-pci,netdev=usernet,mac=52:54:00:00:00:01)
    QEMU+=(-netdev user,id=usernet,hostfwd=tcp::12055-:22)
    QEMU+=(-device qemu-xhci -usb -device usb-kbd)
    QEMU+=(-blockdev node-name=pflash0,driver=file,read-only=on,filename="$CODE")
    QEMU+=(-blockdev node-name=pflash1,driver=file,filename="$VARS")
    QEMU+=(-drive id=disk0,format=raw,file="$DISK",if=none)
fi

# ----[ launch ]--------------------------------------------------------------
echo "arch=$ARCH  os=$OS_NAME"
echo "code:  $CODE"
echo "vars:  $VARS"
echo "disk:  $DISK"
echo ""

exec "${QEMU[@]}"
