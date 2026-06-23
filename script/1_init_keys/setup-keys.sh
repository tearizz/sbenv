#!/bin/bash 
set -e 

KEYS_DIR="../../artifact/keys"
OVMF_DIR="../../artifact/ovmf"

mkdir -p "$KEYS_DIR"

# Generate secure keys
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
virt-fw-vars \
    --input   "$OVMF_DIR"/rv_vars_32m.fd \
    --output  "$OVMF_DIR"/rv_vars_32m.fd \
    --set-pk  "$(uuidgen)" "$KEYS_DIR"/PK.cer \
    --add-kek "$(uuidgen)" "$KEYS_DIR"/KEK.cer \
    --add-db  "$(uuidgen)" "$KEYS_DIR"/DB.cer \
    --secure-boot

virt-fw-vars --input "$OVMF_DIR"/rv_vars_32m.fd --print | grep -E 'PK|KEK|SecureBoot'


