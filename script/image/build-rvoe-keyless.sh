#!/bin/bash
# Keyless variant of build-rvoe.sh.
#
# GRUB and the Linux kernel are signed with OriginSign keyless (Fulcio + Rekor)
# instead of sbsign/DB.crt. Everything else (GPT layout, rootfs, GRUB build,
# DTB, image assembly) is identical, so this wrapper just delegates to
# build-rvoe.sh with --keyless.
#
# Usage:
#   sudo ./script/image/build-rvoe-keyless.sh [--docker]
#
# Difference vs build-rvoe.sh:
#   build-rvoe.sh           GRUB/kernel -> sbsign  (DB.crt, keyed)
#   build-rvoe-keyless.sh   GRUB/kernel -> OriginSign keyless (Fulcio + Rekor)
#
# Both share the same image-build logic; only the signing step branches.
set -e
exec "$(dirname "$0")/build-rvoe.sh" --keyless "$@"
