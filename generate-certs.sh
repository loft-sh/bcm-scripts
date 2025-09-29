#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
usage() {
  cat <<EOF
Usage:
  $0 ca
      # Generate a new CA in ./ca/ca.key and ./ca/ca.pem

  $0 tls <domain> [--namespace NAMESPACE] [--secret-name SECRET_NAME]
      # Generate a TLS cert for <domain> using the CA in ./ca/,
      # include Subject Alternative Names instead of legacy CN,
      # and emit two Kubernetes Secret YAMLs.

Defaults for 'tls':
  NAMESPACE="runai-backend"
  SECRET_NAME="runai-cluster-domain-tls-secret"
EOF
  exit 1
}

# Must have at least one argument
[[ $# -ge 1 ]] || usage

CMD="$1"; shift

case "$CMD" in
  ca)
    [[ $# -eq 0 ]] || usage

    CA_DIR="ca"
    mkdir -p "${CA_DIR}"
    echo "Generating CA in ${CA_DIR}/…"

    # 1) Generate CA private key
    openssl genrsa -out "${CA_DIR}/ca.key" 4096

    # 2) Self-sign to create CA PEM
    openssl req -x509 -new -nodes \
      -key "${CA_DIR}/ca.key" \
      -sha256 \
      -days 3650 \
      -subj "/CN=My Root CA" \
      -out "${CA_DIR}/ca.pem" \
      > /dev/null 2>&1

    echo "Done: ${CA_DIR}/ca.key, ${CA_DIR}/ca.pem"
    ;;

  tls)
    # defaults
    NAMESPACE="runai-backend"
    SECRET_NAME="runai-cluster-domain-tls-secret"
    DOMAIN=""

    # parse flags + domain
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --namespace)
          [[ -n "${2-}" && "${2:0:1}" != "-" ]] || { echo "Error: --namespace requires a value"; usage; }
          NAMESPACE="$2"; shift 2
          ;;
        --secret-name)
          [[ -n "${2-}" && "${2:0:1}" != "-" ]] || { echo "Error: --secret-name requires a value"; usage; }
          SECRET_NAME="$2"; shift 2
          ;;
        -* ) echo "Unknown option: $1"; usage; ;;
        * )
          [[ -z "$DOMAIN" ]] && { DOMAIN="$1"; shift; } || { echo "Unexpected argument: $1"; usage; }
          ;;
      esac
    done

    [[ -n "$DOMAIN" ]] || usage

    # intermediate cert dir
    CERT_DIR="_certs"
    mkdir -p "${CERT_DIR}" && cd "${CERT_DIR}"

    # 1) Generate server key
    openssl genrsa -out server.key 2048

    # 2) Create CSR config for SANs
    cat > san.cnf <<EOF
[ req ]
req_extensions = req_ext
distinguished_name = dn
prompt = no

[ dn ]
CN = ${DOMAIN}

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${DOMAIN}
DNS.2 = www.${DOMAIN}
EOF

    # 3) Generate CSR with SANs
    openssl req -new \
      -key server.key \
      -out server.csr \
      -config san.cnf \
      > /dev/null 2>&1

    # 4) Create v3 extension file for signing
    cat > v3.ext <<EOF
[ v3_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${DOMAIN}
DNS.2 = www.${DOMAIN}
EOF

    # 5) Sign the CSR with existing CA, including SANs
    openssl x509 -req \
      -in server.csr \
      -CA ../ca/ca.pem \
      -CAkey ../ca/ca.key \
      -CAcreateserial \
      -out server.crt \
      -days 825 \
      -sha256 \
      -extensions v3_ext \
      -extfile v3.ext \
      > /dev/null 2>&1

    # 6) Full chain
    cat server.crt ../ca/ca.pem > fullchain.pem

    # 7) Base64-encode (no newlines)
    CRT_B64=$(base64 -w0 < fullchain.pem)
    KEY_B64=$(base64 -w0 < server.key)
    CA_B64=$(base64 -w0 < ../ca/ca.pem)

    # 8) Emit Secrets
    cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
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

    # cleanup
    cd .. && rm -rf "${CERT_DIR}"
    ;;

  *)
    usage
    ;;
esac
