#!/bin/bash
set -e 

SCRIPT_NAME=$(basename "$0")

# =============================
#   S1. 构建 Log Configuration
# =============================
COLOR_INFO='\033[0;32m'     # Green
COLOR_WARN='\033[1;33m'     # Yellow
COLOR_ERROR='\033[0;31m'    # Red
COLOR_TITLE='\033[0;35m'    # Pink
COLOR_RESET='\033[0m'       # White

log_info(){
    local line func file
    read line func file <<< "$(caller 0)"
    printf "${COLOR_INFO}[INFO] [%s:%d] %s${COLOR_RESET}\n" "$file" "$line" "$*" >&2
}
log_warn(){
    local line func file
    read line func file <<< "$(caller 0)"
    printf "${COLOR_WARN}[WARN] [%s:%d] %s${COLOR_RESET}\n" "$file" "$line" "$*" >&2
}
log_error(){
    local line func file
    read line func file <<< "$(caller 0)"
    printf "${COLOR_ERROR}[ERROR] [%s:%d] %s${COLOR_RESET}\n" "$file" "$line" "$*" >&2
    usage
    exit
}
log_blank(){
  printf "${COLOR_RESET} %s\n" "$*" 
}

# =============================
#   S2. Artifact Configuration
# =============================
artifact_path="$PWD/artifact"
declare -A DISK_IMAGE=(
    [x86:ubuntu]="$artifact_path/image/x86_ubuntu.img"
    [x86:openEuler]="$artifact_path/image/x86_openEuler.img"
    [rv:ubuntu]=""
    [rv:openEuler]="$artifact_path/images/RiscV_OpenEuler.img"
)

declare -A OVMF_CODE=(
    [x86:secureboot]="$artifact_path/ovmf/x86_sec_code.fd"
    [x86:unsecureboot]=""
    [rv:secureboot]="$artifact_path/ovmf/rv_code_32m.fd"
    [rv:unsecureboot]="$artifact_path/ovmf/rv_unsec_code.fd"
)

declare -A OVMF_VARS=(
    [x86:secureboot]="$artifact_path/ovmf/x86_sec_vars.fd"
    [x86:unsecureboot]=""
    [rv:secureboot]="$artifact_path/ovmf/rv_vars_32m.fd"
    [rv:unsecureboot]="$artifact_path/ovmf/rv_unsec_vars.fd"
)

# =============================
#   S3. Command Args
# =============================
usage() {
    cat <<EOF
用法： $SCRIPT_NAME [选项] <参数>...
选项：
    -h, --help      获取帮助
    -a, --arch <>   启动的虚机架构(64位)
    -k, --kernel <> 启动的系统内核
    --secureboot    启用安全启动
    --unsecureboot  关闭安全启动
EOF
    log_blank
    exit 0
}

# getopt parse args
SHORT_OPTS="ha:k:"
LONG_OPTS="help,arch:,kernel:,secureboot,unsecureboot"

ARGS=$(getopt -o "$SHORT_OPTS" -l "$LONG_OPTS" -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then
    exit
fi

eval set -- "$ARGS"

ARCH=""
KERNEL=""
SECURE_BOOT=""

while true; do
    case "$1" in 
        -h|--help)
            usage
            ;;
        -a|--arch)
            ARCH="$2"
            shift 2
            ;;
        -k|--kernel)
            KERNEL="$2"
            shift 2
            ;;
        --secureboot)
            SECURE_BOOT="secureboot"
            shift
            ;;
        --unsecureboot)
            SECURE_BOOT="unsecureboot"
            shift
            ;;
        --)
            shift   # "--" marks the end of the options; exit the loop
            break
            ;;
        *)
            echo "内部错误"
            exit 1
            ;;
    esac
done

# check args validity
if [ -z "$ARCH" ]; then
    log_error "必须指定架构：-a|--arch=<rv,x86>"
elif [[ "$ARCH" != "rv" && "$ARCH" != "x86" ]]; then
    log_error "ARCH 必须为 'rv' 或 'x86'"
fi

if [ -z "$KERNEL" ]; then
    log_error "必须指定内核：-k|--kernel=<openEuler,ubuntu>"
elif [[ "$KERNEL" != "openEuler" && "$KERNEL" != "ubuntu" ]]; then
    log_error "KERNEL 必须为 'openEuler' 或 'ubuntu'"
fi

if [[ $SECURE_BOOT != "secureboot" && $SECURE_BOOT != "unsecureboot" ]]; then
    log_error "必须指定是否开启安全启动：--secureboot | --unsecureboot"
fi

# =============================
#   S4. Build Qemu Command
# =============================
BaseCommand=(sudo -S)

if [[ $ARCH = "x86" ]]; then
    BaseCommand+=(qemu-system-x86_64)
    BaseCommand+=(-machine)
    BaseCommand+=(q35,smm=on)
    BaseCommand+=(-cpu host --enable-kvm)
    BaseCommand+=(-vga std)
    BaseCommand+=(-device isa-debug-exit,iobase=0xf4,iosize=0x04)
    BaseCommand+=(-device virtio-rng-pci)
    BaseCommand+=(-nodefaults)
    
    BaseCommand+=(-boot menu=on,splash-time=0)
    BaseCommand+=(-smp 4 -m 4G)
    BaseCommand+=(-no-reboot -nographic)
    BaseCommand+=(-serial mon:stdio)
    BaseCommand+=(-netdev user,id=net0,hostfwd=tcp::12055-:22)
    BaseCommand+=(-device virtio-net-pci,netdev=net0)
else
    BaseCommand+=(qemu-system-riscv64)
    BaseCommand+=(-nographic -machine virt,pflash0=pflash0,pflash1=pflash1,acpi=off)
    BaseCommand+=(-cpu rva23s64,sv39=on,zkr=true)
    # SMP=1:     grub RISC-V模块用"-mcmodel=medlow"编译, SMP>1时relocation overflow
    # Memory=4G: 8G会导致固件将grub加载到过高地址，同样触发overflow
    BaseCommand+=(-smp 1 -m 4G)
    BaseCommand+=(-object rng-random,filename=/dev/urandom,id=rng0)
    BaseCommand+=(-device virtio-vga)
    BaseCommand+=(-device virtio-rng-device,rng=rng0)
    BaseCommand+=(-device virtio-blk-device,drive=disk0)
    BaseCommand+=(-device virtio-net-pci,netdev=usernet,mac=52:54:00:00:00:01)
    BaseCommand+=(-netdev user,id=usernet,hostfwd=tcp::12055-:22)
    BaseCommand+=(-device qemu-xhci -usb -device usb-kbd)
fi

CODE=${OVMF_CODE[$ARCH:$SECURE_BOOT]}
VARS=${OVMF_VARS[$ARCH:$SECURE_BOOT]}

BaseCommand+=(-blockdev node-name=pflash0,driver=file,read-only=on,filename=$CODE)
BaseCommand+=(-blockdev node-name=pflash1,driver=file,filename=$VARS)

DISK=${DISK_IMAGE[$ARCH:$KERNEL]}
if [[ $ARCH = "x86" ]]; then
    BaseCommand+=(-drive if=ide,format=raw,file=$DISK)
else
    BaseCommand+=(-drive id=disk0,format=raw,file=$DISK,if=none)
fi

# =============================
#   S5. Run Qemu Command
# =============================
"${BaseCommand[@]}"
