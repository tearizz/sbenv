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

# Generate secure keys (architecture-independent)
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

# Inject keys into VARS and enable Secure Boot
echo "[INFO] Injecting keys into $VARS_FILE ..."
virt-fw-vars \
    --input   "$OVMF_DIR"/"$VARS_FILE" \
    --output  "$OVMF_DIR"/"$VARS_FILE" \
    --set-pk  "$(uuidgen)" "$KEYS_DIR"/PK.cer \
    --add-kek "$(uuidgen)" "$KEYS_DIR"/KEK.cer \
    --add-db  "$(uuidgen)" "$KEYS_DIR"/DB.cer \
    --secure-boot

virt-fw-vars --input "$OVMF_DIR"/"$VARS_FILE" --print | grep -E 'PK|KEK|SecureBoot'
