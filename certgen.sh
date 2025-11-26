#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

#############################################
# COLOR DEFINITIONS
#############################################
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
BOLD="\033[1m"
RESET="\033[0m"

#############################################
# DIRECTORIES
#############################################
BASE_DIR="$(pwd)"
CA_DIR="${BASE_DIR}/ca"
CERTS_BASE="${BASE_DIR}/certs"

CA_KEY="${CA_DIR}/rootCA.key"
CA_CERT="${CA_DIR}/rootCA.pem"
CA_SERIAL="${CA_DIR}/rootCA.srl"

CA_DAYS=3650
CERT_DAYS=825

# Defaults
COUNTRY="SG"
STATE="Singapore"
LOCALITY="Singapore"
ORG="HomeLab"
ORG_UNIT="NginxProxy"
CA_CN="HomeLab Root CA"

FORCE_NEW_CA=false

#############################################
# HELP MENU
#############################################
show_help() {
	cat <<EOF


 ██████╗███████╗██████╗ ████████╗ ██████╗ ███████╗███╗   ██╗
██╔════╝██╔════╝██╔══██╗╚══██╔══╝██╔════╝ ██╔════╝████╗  ██║
██║     █████╗  ██████╔╝   ██║   ██║  ███╗█████╗  ██╔██╗ ██║
██║     ██╔══╝  ██╔══██╗   ██║   ██║   ██║██╔══╝  ██║╚██╗██║
╚██████╗███████╗██║  ██║   ██║   ╚██████╔╝███████╗██║ ╚████║
 ╚═════╝╚══════╝╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚══════╝╚═╝  ╚═══╝

            CertGen - TLS Certificate Generator


Usage: ${SCRIPT_NAME} [options] <domain> [wildcard]

Generate a Root CA and SSL certificate for Nginx Proxy Manager.
Files are created relative to the current directory.

Arguments:
  <domain>       Domain name for certificate generation.
  wildcard       Add wildcard SAN entry (*.domain).

Options:
  -h, --help         Show this help.
  --force-new-ca     Backup old ./ca/ and create a new Root CA.

Examples:
  ${SCRIPT_NAME} mydomain.local
  ${SCRIPT_NAME} example.com wildcard
  ${SCRIPT_NAME} --force-new-ca internal.lan

Folders:
  ./ca/                  Root CA
  ./certs/<domain>/      Domain certs + config
  ./ca_backup_<timestamp>/  (if --force-new-ca used)

EOF
}

#############################################
# PARSE OPTIONS
#############################################
ARGS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	--force-new-ca)
		FORCE_NEW_CA=true
		shift
		;;
	-h | --help)
		show_help
		exit 0
		;;
	-*)
		echo -e "Unknown option: $1"
		echo
		show_help
		exit 1
		;;
	*)
		ARGS+=("$1")
		shift
		;;
	esac
done

set -- "${ARGS[@]:-}"

if [ $# -lt 1 ]; then
	show_help
	exit 1
fi

DOMAIN="$1"
WILDCARD="${2:-}"

echo -e "=== Working Directory: ${BASE_DIR}"
echo -e "=== CA Directory: ${CA_DIR}"
echo

#############################################
# BANNER
#############################################
echo -e "
 ██████╗███████╗██████╗ ████████╗ ██████╗ ███████╗███╗   ██╗
██╔════╝██╔════╝██╔══██╗╚══██╔══╝██╔════╝ ██╔════╝████╗  ██║
██║     █████╗  ██████╔╝   ██║   ██║  ███╗█████╗  ██╔██╗ ██║
██║     ██╔══╝  ██╔══██╗   ██║   ██║   ██║██╔══╝  ██║╚██╗██║
╚██████╗███████╗██║  ██║   ██║   ╚██████╔╝███████╗██║ ╚████║
 ╚═════╝╚══════╝╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚══════╝╚═╝  ╚═══╝

          CertGen - TLS Certificate Generator"

#############################################
# --force-new-ca: Backup old CA
#############################################
if [[ "${FORCE_NEW_CA}" == true ]]; then
	if [ -d "${CA_DIR}" ]; then
		TS="$(date +%Y%m%d_%H%M%S)"
		BACKUP_DIR="${BASE_DIR}/ca_backup_${TS}"
		echo -e ">>> --force-new-ca active: Backing up existing CA to ${BACKUP_DIR}"
		mv "${CA_DIR}" "${BACKUP_DIR}"
	fi
fi

mkdir -p "${CA_DIR}"

#############################################
# Step 1 — Create CA if missing
#############################################
if [ ! -f "${CA_KEY}" ] || [ ! -f "${CA_CERT}" ]; then
	echo -e ">>> Creating new Root CA..."

	openssl genrsa -out "${CA_KEY}" 4096 >/dev/null 2>&1

	openssl req -x509 -new -nodes \
		-key "${CA_KEY}" \
		-sha256 \
		-days "${CA_DAYS}" \
		-out "${CA_CERT}" \
		-subj "/C=${COUNTRY}/ST=${STATE}/L=${LOCALITY}/O=${ORG}/OU=${ORG_UNIT}/CN=${CA_CN}" \
		>/dev/null 2>&1

	echo -e "✔ New Root CA created"
else
	echo -e "✔ Existing Root CA found — reusing (use --force-new-ca to recreate)"
fi

#############################################
# Step 2 — Create domain certificate
#############################################
DOMAIN_DIR="${CERTS_BASE}/${DOMAIN}"
mkdir -p "${DOMAIN_DIR}"

CERT_KEY="${DOMAIN_DIR}/${DOMAIN}.key"
CERT_CSR="${DOMAIN_DIR}/${DOMAIN}.csr"
CERT_CRT="${DOMAIN_DIR}/${DOMAIN}.crt"
CERT_CONF="${DOMAIN_DIR}/openssl.conf"

echo -e ">>> Generating certificate for: ${DOMAIN}"
[ -n "${WILDCARD}" ] && echo -e ">>> Wildcard enabled (*.${DOMAIN})"

ALT_NAMES="DNS.1 = ${DOMAIN}"
if [ -n "${WILDCARD}" ]; then
	ALT_NAMES="${ALT_NAMES}
DNS.2 = *.${DOMAIN}"
fi

# Write OpenSSL config
cat >"${CERT_CONF}" <<EOF
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[dn]
C  = ${COUNTRY}
ST = ${STATE}
L  = ${LOCALITY}
O  = ${ORG}
OU = ${ORG_UNIT}
CN = ${DOMAIN}

[req_ext]
subjectAltName = @alt_names

[alt_names]
${ALT_NAMES}
EOF

openssl genrsa -out "${CERT_KEY}" 2048 >/dev/null 2>&1

openssl req -new \
	-key "${CERT_KEY}" \
	-out "${CERT_CSR}" \
	-config "${CERT_CONF}" \
	>/dev/null 2>&1

openssl x509 -req \
	-in "${CERT_CSR}" \
	-CA "${CA_CERT}" \
	-CAkey "${CA_KEY}" \
	-CAcreateserial \
	-CAserial "${CA_SERIAL}" \
	-out "${CERT_CRT}" \
	-days "${CERT_DAYS}" \
	-sha256 \
	-extensions req_ext \
	-extfile "${CERT_CONF}" \
	>/dev/null 2>&1

echo -e "✔ Certificate created"
echo -e "    Key:  ${CERT_KEY}"
echo -e "    Cert: ${CERT_CRT}"

#############################################
# Summary
#############################################
echo -e "
========================================
✔ All tasks completed successfully!

Root CA:
  ${CA_CERT}
  ${CA_KEY}

Domain Certificate:
  ${CERT_CRT}
  ${CERT_KEY}

To use in Nginx Proxy Manager:
  SSL Certificates → Add → Custom
  Certificate:  ${CERT_CRT}
  Private Key:  ${CERT_KEY}

To trust on devices, import Root CA:
  ${CA_CERT}

========================================
"
