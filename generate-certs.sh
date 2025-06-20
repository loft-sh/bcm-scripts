#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <domain>"
  exit 1
fi

DOMAIN=$1
CERT_DIR="certs/${DOMAIN}"

# Prepare directory
mkdir -p "${CERT_DIR}"
cd "${CERT_DIR}"

# Remove any artifacts from previous runs
rm -f ca.srl server.csr

# 1) Create a CA
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes \
  -key ca.key \
  -sha256 \
  -days 3650 \
  -subj "/CN=${DOMAIN} CA" \
  -out ca.pem

# 2) Create a server key & CSR for ${DOMAIN}
openssl genrsa -out server.key 2048
openssl req -new \
  -key server.key \
  -subj "/CN=${DOMAIN}" \
  -out server.csr

# 3) Sign the CSR with your CA
openssl x509 -req \
  -in server.csr \
  -CA ca.pem \
  -CAkey ca.key \
  -CAcreateserial \
  -out server.crt \
  -days 825 \
  -sha256

# 4) Bundle server + CA into fullchain.pem
cat server.crt ca.pem > fullchain.pem

# 5) Cleanup intermediate files
rm -f ca.srl server.csr

echo "Generated files in ${CERT_DIR}:"
echo "  ca.key        # CA private key"
echo "  ca.pem        # CA certificate (public)"
echo "  server.key    # TLS private key for ${DOMAIN}"
echo "  server.crt    # TLS certificate for ${DOMAIN}"
echo "  fullchain.pem # server.crt + ca.pem"
