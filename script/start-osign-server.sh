#!/bin/bash
# Start the OriginSign Authenticode verification server used by the UEFI shim.
#
# The shim POSTs {"signatures":[...]} to
#   http://<host>:28082/v1/verify/authenticode
# and the server verifies: Fulcio chain + SCT + signature (ECDSA/RSA/SM2)
# + Rekor transparency-log inclusion proof.
#
# Run it in the background from the host, e.g.:
#   nohup ./script/start-osign-server.sh > /tmp/osign-server.log 2>&1 &
#
# Environment overrides:
#   SIGSTORE_ENV    sigstore-env directory (default: /data/code/originsign/sigstore-env)
#   HTTP_PORT       HTTP port               (default: 28082)
#   GRPC_PORT       gRPC port               (default: 29090)
#   FULCIO_URL      Fulcio base URL         (default: http://fulcio.fulcio-system.svc:8080)
#   REKOR_URL       Rekor base URL          (default: http://rekor.rekor-system.svc:8080)
#   TUF_ROOT        TUF cache dir           (default: $SIGSTORE_ENV/tuf-cache)
#   AUDIT_REKOR     require a Rekor entry   (default: true)
#   VERIFY_CERT     verify Fulcio chain+SCT (default: true)
set -e

SIGSTORE_ENV="${SIGSTORE_ENV:-/data/code/originsign/sigstore-env}"
HTTP_PORT="${HTTP_PORT:-28082}"
GRPC_PORT="${GRPC_PORT:-29090}"

[ -f "$SIGSTORE_ENV/deploy-env.sh" ] || { echo "[ERROR] sigstore-env not found: $SIGSTORE_ENV"; exit 1; }
[ -x "$SIGSTORE_ENV/bin/originsign" ] || { echo "[ERROR] originsign not found: $SIGSTORE_ENV/bin/originsign"; exit 1; }

# shellcheck disable=SC1090,SC1091
source "$SIGSTORE_ENV/deploy-env.sh" >/dev/null 2>&1
# shellcheck disable=SC1090,SC1091
source "$SIGSTORE_ENV/endpoints.env" 2>/dev/null || true

export LD_LIBRARY_PATH="/opt/tongsuo/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export FULCIO_URL="${FULCIO_URL:-http://fulcio.fulcio-system.svc:8080}"
export REKOR_URL="${REKOR_URL:-http://rekor.rekor-system.svc:8080}"
export TUF_ROOT="${TUF_ROOT:-$SIGSTORE_ENV/tuf-cache}"
export AUDIT_REKOR="${AUDIT_REKOR:-true}"
export VERIFY_CERT="${VERIFY_CERT:-true}"

echo "== starting OriginSign server"
echo "   HTTP :${HTTP_PORT}  gRPC :${GRPC_PORT}"
echo "   FULCIO_URL=$FULCIO_URL"
echo "   REKOR_URL=$REKOR_URL"
echo "   TUF_ROOT=$TUF_ROOT  AUDIT_REKOR=$AUDIT_REKOR"

exec "$SIGSTORE_ENV/bin/originsign" server \
	--http-port "$HTTP_PORT" \
	--grpc-port "$GRPC_PORT"
