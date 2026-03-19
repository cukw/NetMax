#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo ./deploy/nginx/generate-self-signed.sh
# Optional overrides:
#   CERT_DIR=/etc/ssl/netmax CERT_IP=155.212.141.80 DAYS=825 sudo ./deploy/nginx/generate-self-signed.sh

CERT_DIR="${CERT_DIR:-/etc/ssl/netmax}"
CERT_IP="${CERT_IP:-155.212.141.80}"
DAYS="${DAYS:-825}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENSSL_CONFIG="${SCRIPT_DIR}/openssl-selfsigned.cnf"

if [[ ! -f "${OPENSSL_CONFIG}" ]]; then
  echo "OpenSSL config not found: ${OPENSSL_CONFIG}" >&2
  exit 1
fi

if [[ "${CERT_IP}" != "155.212.141.80" ]]; then
  TMP_CONFIG="$(mktemp)"
  trap 'rm -f "${TMP_CONFIG}"' EXIT
  sed "s/155\\.212\\.141\\.80/${CERT_IP}/g" "${OPENSSL_CONFIG}" > "${TMP_CONFIG}"
  OPENSSL_CONFIG="${TMP_CONFIG}"
fi

install -d -m 0755 "${CERT_DIR}"

openssl req -x509 -nodes -newkey rsa:4096 \
  -days "${DAYS}" \
  -keyout "${CERT_DIR}/privkey.pem" \
  -out "${CERT_DIR}/fullchain.pem" \
  -config "${OPENSSL_CONFIG}" \
  -extensions v3_req

chmod 600 "${CERT_DIR}/privkey.pem"
chmod 644 "${CERT_DIR}/fullchain.pem"

echo "Self-signed certificate created:"
echo "  cert: ${CERT_DIR}/fullchain.pem"
echo "  key:  ${CERT_DIR}/privkey.pem"
echo "  ip:   ${CERT_IP}"
