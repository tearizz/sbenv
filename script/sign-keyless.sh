#!/bin/bash
# Sign one or more PE/EFI files with OriginSign keyless (Fulcio + Rekor).
#
# The resulting artifact carries ONLY an OriginSign keyless signature (the
# existing signature table is overwritten), so the UEFI shim will take the
# remote HTTP verification path instead of the local DB fallback.
#
# Requirements:
#   - a deployed sigstore-env (Fulcio / Rekor / TUF) reachable from this host
#   - $ORIGINSIGN_BIN (default: <sigstore-env>/bin/originsign)
#
# Usage:
#   ./script/sign-keyless.sh <efi-file> [<efi-file> ...]
#
# Environment overrides:
#   SIGSTORE_ENV    sigstore-env directory (default: /data/code/originsign/sigstore-env)
#   ORIGINSIGN_BIN  originsign binary       (default: $SIGSTORE_ENV/bin/originsign)
#   FULCIO_URL      Fulcio base URL         (default: http://fulcio.fulcio-system.svc:8080)
#   REKOR_URL       Rekor base URL          (default: http://rekor.rekor-system.svc:8080)
#   GETTOKEN_URL    id-token endpoint       (default: http://gettoken.default.svc:8080)
set -e

SIGSTORE_ENV="${SIGSTORE_ENV:-/data/code/originsign/sigstore-env}"
ORIGINSIGN_BIN="${ORIGINSIGN_BIN:-$SIGSTORE_ENV/bin/originsign}"
GETTOKEN_URL="${GETTOKEN_URL:-http://gettoken.default.svc:8080}"

[ -x "$ORIGINSIGN_BIN" ] || { echo "[ERROR] originsign not found: $ORIGINSIGN_BIN"; exit 1; }
[ -f "$SIGSTORE_ENV/deploy-env.sh" ] || { echo "[ERROR] sigstore-env not found: $SIGSTORE_ENV"; exit 1; }

# shellcheck disable=SC1090,SC1091
source "$SIGSTORE_ENV/deploy-env.sh" >/dev/null 2>&1
# shellcheck disable=SC1090,SC1091
source "$SIGSTORE_ENV/endpoints.env" 2>/dev/null || true

export LD_LIBRARY_PATH="/opt/tongsuo/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export FULCIO_URL="${FULCIO_URL:-http://fulcio.fulcio-system.svc:8080}"
export REKOR_URL="${REKOR_URL:-http://rekor.rekor-system.svc:8080}"

[ $# -ge 1 ] || { echo "usage: $0 <efi-file> [<efi-file> ...]"; exit 1; }

echo "== fetching id-token from $GETTOKEN_URL"
IDTOKEN="$(curl -s -m 10 "$GETTOKEN_URL")"
[ -n "$IDTOKEN" ] || { echo "[ERROR] failed to fetch id-token"; exit 1; }

for efi in "$@"; do
	[ -f "$efi" ] || { echo "[ERROR] not found: $efi"; exit 1; }

	echo "== keyless sign: $efi"
	# --output is a directory: it receives the signed artifact and certificate.json.
	tmpdir="$(mktemp -d)"
	if ! "$ORIGINSIGN_BIN" sign \
		--artifact "$efi" \
		--id-token "$IDTOKEN" \
		--cert-mgr fulcio --cert-mgr-url "$FULCIO_URL" \
		--sign-mgr rekor --sign-mgr-url "$REKOR_URL" \
		--sign-tool go-crypto --algo ecdsa \
		--embed-sign --overwrite --force \
		--output "$tmpdir"; then
		rm -rf "$tmpdir"
		echo "[ERROR] keyless sign failed: $efi"
		exit 1
	fi
	signed="$tmpdir/$(basename "$efi")"
	if [ ! -f "$signed" ]; then
		rm -rf "$tmpdir"
		echo "[ERROR] signed artifact not produced: $signed"
		exit 1
	fi
	# Write in place so the file keeps its owner/permissions.
	cat "$signed" > "$efi"
	rm -rf "$tmpdir"
done

echo "== keyless signing done"
