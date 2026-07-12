#!/usr/bin/env bash
#
# generate-cluster-certs.sh
#
# Certs for a 3-node NiFi cluster on a single Docker Swarm host.
#
# Key design choice: all 3 nodes share ONE certificate (same CN, multi-SAN
# covering every node's service name) rather than 3 separate node certs.
# This is a deliberate, officially-documented simplification for
# same-host clusters (see Apache NiFi's own secure-cluster setup guide) -
# NiFi's docker image only supports ONE "Node Identity" env var per node
# (secure.sh only fills in a single "Node Identity 1" placeholder), so
# giving every node the same cert means one shared identity covers all
# of them, instead of needing 3 separate identities registered by hand
# after boot (which the docker image has no env-var mechanism for at all).
#
# Output:
#   certs/ca.key, ca.crt              the CA
#   certs/node-shared.key/.crt/.p12   ONE cert used by all 3 NiFi nodes,
#                                     both as their HTTPS server identity
#                                     AND as their cluster-protocol client
#                                     identity when talking to each other
#   certs/truststore.jks              CA cert, trusted by all nodes
#   certs/admin.key/.crt/.p12         browser login cert (separate identity)
#   .env                              passwords + identities for the stack
#
# Usage: run from the project root (same dir as docker-stack.yml):
#   bash scripts/generate-cluster-certs.sh [--force]

set -euo pipefail

ROOT_DIR="$(pwd)"
CERTS_DIR="${ROOT_DIR}/certs"
FORCE="${1:-}"

echo "Writing certs/ and .env under: ${ROOT_DIR}"
echo "(this is your current directory - cd elsewhere first if that's wrong)"
echo

# ---- Configurable identity fields -----------------------------------------
ORG_OU="${ORG_OU:-NIFI}"
ORG_O="${ORG_O:-MyOrg}"
ORG_L="${ORG_L:-Lagos}"
ORG_ST="${ORG_ST:-Lagos}"
ORG_C="${ORG_C:-NG}"

NODE_CN="${NODE_CN:-nifi-cluster-node}"
ADMIN_CN="${ADMIN_CN:-admin}"
ADMIN_OU="${ADMIN_OU:-NiFiUsers}"

# Swarm service names the 3 nodes will be reachable at on the overlay
# network - must match the service names in docker-stack.yml exactly.
NODE_SERVICE_NAMES="${NODE_SERVICE_NAMES:-nifi-node1 nifi-node2 nifi-node3}"

DAYS_VALID="${DAYS_VALID:-825}"
CA_DAYS_VALID="${CA_DAYS_VALID:-3650}"

# Same RDN-order gotcha as the single-node project: openssl's "-subj"
# lists CN first, but NiFi/Java report identities with C first, CN last.
# Confirmed against a live NiFi log in the single-node project - reused
# here rather than re-derived, since the underlying cause (Java's
# X500Principal RFC2253 ordering) doesn't change between setups.
NODE_IDENTITY="C=${ORG_C}, ST=${ORG_ST}, L=${ORG_L}, O=${ORG_O}, OU=${ORG_OU}, CN=${NODE_CN}"
INITIAL_ADMIN_IDENTITY="C=${ORG_C}, ST=${ORG_ST}, L=${ORG_L}, O=${ORG_O}, OU=${ADMIN_OU}, CN=${ADMIN_CN}"

if [[ -d "${CERTS_DIR}" && "${FORCE}" != "--force" ]]; then
  echo "certs/ already exists. Re-run with --force to regenerate." >&2
  exit 1
fi

# Preserve the sensitive props key across regenerations, same reasoning
# as the single-node project - it's independent of the certs, and losing
# it makes anything already encrypted with it unrecoverable. For a
# cluster this matters even more: ALL nodes must share the exact same
# key, since flow.xml.gz (with encrypted sensitive properties) is
# synced across the cluster - mismatched keys break that sync outright.
EXISTING_SENSITIVE_KEY=""
if [[ -f "${ROOT_DIR}/.env" ]]; then
  EXISTING_SENSITIVE_KEY="$(grep '^SENSITIVE_PROPS_KEY=' "${ROOT_DIR}/.env" 2>/dev/null | cut -d= -f2-)"
fi

rm -rf "${CERTS_DIR}"
mkdir -p "${CERTS_DIR}"
cd "${CERTS_DIR}"

gen_pass() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-24; }

CA_PASS="$(gen_pass)"
KEYSTORE_PASSWORD="$(gen_pass)"
KEY_PASSWORD="${KEYSTORE_PASSWORD}"
TRUSTSTORE_PASSWORD="$(gen_pass)"
ADMIN_P12_PASSWORD="$(gen_pass)"

if [[ -n "${EXISTING_SENSITIVE_KEY}" ]]; then
  SENSITIVE_PROPS_KEY="${EXISTING_SENSITIVE_KEY}"
  echo "==> Reusing existing SENSITIVE_PROPS_KEY from .env"
else
  SENSITIVE_PROPS_KEY="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)"
fi

echo "==> [1/4] Generating CA"
openssl genrsa -aes256 -passout pass:"${CA_PASS}" -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -passin pass:"${CA_PASS}" -sha256 -days "${CA_DAYS_VALID}" \
  -out ca.crt -subj "/CN=NiFi Cluster Lab CA/OU=${ORG_OU}/O=${ORG_O}/L=${ORG_L}/ST=${ORG_ST}/C=${ORG_C}"

echo "==> [2/4] Generating the ONE shared node certificate for all 3 nodes"
openssl genrsa -out node-shared.key 2048
openssl req -new -key node-shared.key -out node-shared.csr \
  -subj "/CN=${NODE_CN}/OU=${ORG_OU}/O=${ORG_O}/L=${ORG_L}/ST=${ORG_ST}/C=${ORG_C}"

# SAN covers every node's Swarm service name (how nodes reach each other
# on the overlay network) plus localhost/127.0.0.1 for browser access to
# whichever node's published port you connect to. EKU includes BOTH
# serverAuth and clientAuth: each node is a TLS *server* for the web UI
# and cluster protocol, but also a TLS *client* when it connects out to
# its peer nodes - the same cert has to work both ways.
{
  echo "basicConstraints=CA:FALSE"
  echo "keyUsage = digitalSignature, keyEncipherment"
  echo "extendedKeyUsage = serverAuth, clientAuth"
  echo "subjectAltName = @alt_names"
  echo
  echo "[alt_names]"
  i=1
  for name in ${NODE_SERVICE_NAMES} localhost; do
    echo "DNS.${i} = ${name}"
    i=$((i+1))
  done
  echo "IP.1 = 127.0.0.1"
} > node-shared.ext

openssl x509 -req -in node-shared.csr -CA ca.crt -CAkey ca.key -passin pass:"${CA_PASS}" \
  -CAcreateserial -out node-shared.crt -days "${DAYS_VALID}" -sha256 -extfile node-shared.ext

echo "==> [3/4] Packaging node-shared.p12 (mounted into all 3 node containers)"
openssl pkcs12 -export -in node-shared.crt -inkey node-shared.key \
  -out node-shared.p12 -name nifi-cluster-node -CAfile ca.crt -caname root -chain \
  -passout pass:"${KEYSTORE_PASSWORD}"

echo "==> Building JKS truststore (CA cert only, forced true JKS format)"
keytool -import -noprompt -trustcacerts \
  -alias rootCA -file ca.crt \
  -keystore truststore.jks -storetype JKS -storepass "${TRUSTSTORE_PASSWORD}"

echo "==> [4/4] Generating admin client certificate (${INITIAL_ADMIN_IDENTITY})"
openssl genrsa -out admin.key 2048
openssl req -new -key admin.key -out admin.csr \
  -subj "/CN=${ADMIN_CN}/OU=${ADMIN_OU}/O=${ORG_O}/L=${ORG_L}/ST=${ORG_ST}/C=${ORG_C}"
{
  echo "basicConstraints=CA:FALSE"
  echo "keyUsage = digitalSignature, keyEncipherment"
  echo "extendedKeyUsage = clientAuth"
} > admin.ext
openssl x509 -req -in admin.csr -CA ca.crt -CAkey ca.key -passin pass:"${CA_PASS}" \
  -CAcreateserial -out admin.crt -days "${DAYS_VALID}" -sha256 -extfile admin.ext
openssl pkcs12 -export -in admin.crt -inkey admin.key \
  -out admin.p12 -name admin -CAfile ca.crt -caname root -chain \
  -passout pass:"${ADMIN_P12_PASSWORD}"

chmod 600 ca.key node-shared.key admin.key
rm -f node-shared.ext admin.ext
cd "${ROOT_DIR}"

cat > "${ROOT_DIR}/.env" <<EOF
# Generated by scripts/generate-cluster-certs.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
KEYSTORE_PASSWORD=${KEYSTORE_PASSWORD}
KEY_PASSWORD=${KEY_PASSWORD}
TRUSTSTORE_PASSWORD=${TRUSTSTORE_PASSWORD}
ADMIN_P12_PASSWORD=${ADMIN_P12_PASSWORD}
NODE_IDENTITY=${NODE_IDENTITY}
INITIAL_ADMIN_IDENTITY=${INITIAL_ADMIN_IDENTITY}
SENSITIVE_PROPS_KEY=${SENSITIVE_PROPS_KEY}
EOF

echo
echo "==================================================================="
echo "Done. Files written under ${CERTS_DIR}"
echo
echo "Import into your browser to log in as admin:"
echo "  ${CERTS_DIR}/admin.p12  (password: ADMIN_P12_PASSWORD in .env)"
echo
echo "Shared node identity (all 3 nodes present this same cert):"
echo "  ${NODE_IDENTITY}"
echo
echo "Admin identity:"
echo "  ${INITIAL_ADMIN_IDENTITY}"
echo "==================================================================="
