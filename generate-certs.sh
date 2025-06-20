#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <domain> [--namespace NAMESPACE]"
  exit 1
}

# defaults
NAMESPACE="runai-backend"

# must have at least a domain
if [ $# -lt 1 ]; then
  usage
fi

# parse args
DOMAIN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      if [ -n "${2-}" ] && [[ ! "$2" =~ ^- ]]; then
        NAMESPACE="$2"
        shift 2
      else
        echo "Error: --namespace requires a value"
        usage
      fi
      ;;
    -*)
      echo "Unknown option: $1"
      usage
      ;;
    *)
      if [ -z "$DOMAIN" ]; then
        DOMAIN="$1"
        shift
      else
        echo "Unexpected argument: $1"
        usage
      fi
      ;;
  esac
done

if [ -z "$DOMAIN" ]; then
  usage
fi

CERT_DIR="_certs"

# Prepare directory
mkdir -p "${CERT_DIR}"
cd "${CERT_DIR}"

# 1) Create a CA
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes \
  -key ca.key \
  -sha256 \
  -days 3650 \
  -subj "/CN=${DOMAIN} CA" \
  -out ca.pem > /dev/null 2>&1

# 2) Create a server key & CSR for ${DOMAIN}
openssl genrsa -out server.key 2048
openssl req -new \
  -key server.key \
  -subj "/CN=${DOMAIN}" \
  -out server.csr > /dev/null 2>&1

# 3) Sign the CSR with your CA
openssl x509 -req \
  -in server.csr \
  -CA ca.pem \
  -CAkey ca.key \
  -CAcreateserial \
  -out server.crt \
  -days 825 \
  -sha256 > /dev/null 2>&1

# 4) Bundle server + CA into fullchain.pem
cat server.crt ca.pem > fullchain.pem

# 5) Base64-encode for Kubernetes secrets (no newlines)
CRT_B64=$(cat fullchain.pem | base64)
KEY_B64=$(cat server.key | base64)
CA_B64=$(cat ca.pem | base64)

# 6) Emit the two Secret manifests
cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: runai-cluster-domain-tls-secret
  namespace: ${NAMESPACE}
type: kubernetes.io/tls
data:
  tls.crt: ${CRT_B64}
  tls.key: ${KEY_B64}
---
apiVersion: v1
kind: Secret
metadata:
  name: runai-ca-cert
  namespace: ${NAMESPACE}
  labels:
    run.ai/cluster-wide: "true"
    run.ai/name: "runai-ca-cert"
type: Opaque
data:
  runai-ca.pem: ${CA_B64}
EOF

# 7) Cleanup 
cd ..
rm -rf "${CERT_DIR}"
