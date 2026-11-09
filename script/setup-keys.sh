#!/bin/bash
set -e

# =============================================================================
# setup-keys.sh — UEFI Secure Boot 密钥生成与固件注入
#
# 用法:
#   ./script/setup-keys.sh              # 默认 riscv64
#   ./script/setup-keys.sh riscv64      # RISC-V
#   ./script/setup-keys.sh x86_64       # x86_64
# =============================================================================

ARCH="${1:-riscv64}"

case "$ARCH" in
    riscv64)
        VARS_FILE="rvvars.fd"
        ;;
    x86_64)
        VARS_FILE="x86vars.fd"
        ;;
    *)
        echo "ERROR: Unsupported ARCH '$ARCH'. Valid: riscv64, x86_64"
        exit 1
        ;;
esac

KEYS_DIR="../artifact/keys"
OVMF_DIR="../artifact/ovmf"

mkdir -p "$KEYS_DIR"

# Generate secure keys (architecture-independent).
# 重要：只在密钥不存在时才生成。若每次运行都重新 openssl 生成，会导致
# "riscv64 跑一次 + x86_64 跑一次" 生成两套不同密钥，出现固件 DB 与签名 DB
# 不一致、Secure Boot 报 Access Denied 的问题。因此这里做成幂等：首先生成，
# 后续（另一架构）复用同一套密钥。
if [ ! -f "$KEYS_DIR/DB.key" ] || [ ! -f "$KEYS_DIR/DB.crt" ]; then
    openssl req -new -x509 -newkey rsa:2048 -subj "/CN=PK/" \
        -keyout "$KEYS_DIR"/PK.key -out "$KEYS_DIR"/PK.crt \
        -days 3650 -nodes -sha256
    openssl req -new -x509 -newkey rsa:2048 -subj "/CN=KEK/" \
        -keyout "$KEYS_DIR"/KEK.key -out "$KEYS_DIR"/KEK.crt \
        -days 3650 -nodes -sha256
    openssl req -new -x509 -newkey rsa:2048 -subj "/CN=DB/" \
        -keyout "$KEYS_DIR"/DB.key -out "$KEYS_DIR"/DB.crt \
        -days 3650 -nodes -sha256

    # Convert to DER (required by virt-fw-vars)
    openssl x509 -in "$KEYS_DIR"/PK.crt  -outform DER -out "$KEYS_DIR"/PK.cer
    openssl x509 -in "$KEYS_DIR"/KEK.crt -outform DER -out "$KEYS_DIR"/KEK.cer
    openssl x509 -in "$KEYS_DIR"/DB.crt  -outform DER -out "$KEYS_DIR"/DB.cer
else
    echo "[INFO] keys already exist under $KEYS_DIR, reusing them"
fi

# Inject keys into VARS and enable Secure Boot
echo "[INFO] Injecting keys into $VARS_FILE ..."
virt-fw-vars \
    --input   "$OVMF_DIR"/"$VARS_FILE" \
    --output  "$OVMF_DIR"/"$VARS_FILE" \
    --set-pk  "$(uuidgen)" "$KEYS_DIR"/PK.cer \
    --add-kek "$(uuidgen)" "$KEYS_DIR"/KEK.cer \
    --add-db  "$(uuidgen)" "$KEYS_DIR"/DB.cer \
    --secure-boot

# RISC-V: QEMU virt 机器的 pflash（CODE 与 VARS）都必须 32MB 对齐。
# 必须在注入密钥之后再 truncate（只追加零，不破坏已写入的变量区），
# 否则 virt-fw-vars 重写文件时可能把大小缩回原始 VARS 尺寸。
if [ "$ARCH" = "riscv64" ]; then
    truncate -s 32M "$OVMF_DIR"/"$VARS_FILE"
fi

virt-fw-vars --input "$OVMF_DIR"/"$VARS_FILE" --print | grep -E 'PK|KEK|SecureBoot'
