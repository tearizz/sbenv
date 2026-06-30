#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_COMMIT=$(cat "$SCRIPT_DIR/resources/edk2-base-commit.txt")
EDK2_DIR="$PROJECT_ROOT/artifact/edk2"

if [ -d "$EDK2_DIR" ]; then
    echo "[SKIP] edk2 already exists"
    exit 0
fi

echo "[CLONE] EDK2 from github.com/tianocore/edk2 ..."
git clone --depth 1 https://github.com/tianocore/edk2.git "$EDK2_DIR"
cd "$EDK2_DIR"
git fetch --depth 1 origin "$BASE_COMMIT"
git checkout "$BASE_COMMIT"

echo "[SUBMODULE] Initializing submodules ..."
git submodule update --init --recursive --depth 1

echo "[PATCH] Applying RISC-V secure boot patches ..."
git apply "$SCRIPT_DIR/resources/edk2-riscv.patch"

echo "[PATCH] Applying x86_64 secure boot patch ..."
git apply "$SCRIPT_DIR/resources/edk2-x64.patch"

echo "[DONE] EDK2 setup complete"
