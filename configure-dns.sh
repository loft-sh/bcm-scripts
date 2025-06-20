#!/usr/bin/env bash
#
# configure-dns.sh – add or remove BIND zones (supports wildcard records)
# Usage:
#   ./configure-dns.sh add    <domain> <ip>
#   ./configure-dns.sh remove <domain>
#
set -euo pipefail

CONFIG="/etc/bind/named.conf.include"
ZONE_DIR="/etc/bind"
RNDC="rndc"

function usage() {
    cat <<EOF
Usage:
  $0 add    <domain> <ip>     # add or overwrite a zone (domain or *.domain)
  $0 remove <domain>          # remove a zone (domain or "*.domain")
Examples:
  $0 add loft.bcm.com     192.168.0.1
  $0 add *.example.com    10.10.10.10
  $0 remove loft.bcm.com
  $0 remove "*.example.com"
EOF
    exit 1
}

# must be run as root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: this script must be run as root." >&2
    exit 1
fi

if [[ $# -lt 2 ]]; then
    usage
fi

ACTION=$1
RAW_DOMAIN=$2

# Determine if wildcard record is requested
if [[ "$RAW_DOMAIN" == \*.* ]]; then
    WILDCARD=true
    # strip leading '*.' to get the real zone name
    ZONE_NAME="${RAW_DOMAIN#\*.}"
else
    WILDCARD=false
    ZONE_NAME="$RAW_DOMAIN"
fi

# sanitize zone file name: replace '*' with '_wildcard'
ZONE_FILE_NAME="${RAW_DOMAIN//\*/_wildcard}.zone"
ZONE_FILE_PATH="${ZONE_DIR}/${ZONE_FILE_NAME}"

function remove_zone_stanza() {
    if grep -qE "^\s*zone\s+\"${ZONE_NAME}\"" "${CONFIG}"; then
        # delete from 'zone "${ZONE_NAME}" {' through the next '};'
        sed -i "/^\s*zone[[:space:]]+\"${ZONE_NAME}\"/,/};/d" "${CONFIG}"
        echo "Removed zone stanza for ${ZONE_NAME} from ${CONFIG}"
    else
        echo "No existing zone stanza for ${ZONE_NAME} in ${CONFIG}"
    fi
}

case "$ACTION" in
    add)
        if [[ $# -ne 3 ]]; then
            usage
        fi
        IP=$3

        # remove any existing stanza (so we can overwrite)
        remove_zone_stanza

        # append new zone stanza
        cat >> "${CONFIG}" <<EOF

zone "${ZONE_NAME}" {
    type master;
    file "${ZONE_FILE_NAME}";
};
EOF
        echo "Appended zone stanza for ${ZONE_NAME} to ${CONFIG}"

        # generate minimal zone file
        cat > "${ZONE_FILE_PATH}" <<EOF
\$TTL    86400
@       IN      SOA     localhost. root.localhost. (
                            $(date +%y%m%d%H%M) ; serial (YYYYMMDDhhmm)
                            3600             ; refresh
                            1800             ; retry
                            604800           ; expire
                            86400            ; minimum
)
        IN      NS      localhost.
@       IN      A       ${IP}
EOF
        
        # add wildcard record if requested
        if [[ "$WILDCARD" == true ]]; then
            echo "*       IN      A       ${IP}" >> "${ZONE_FILE_PATH}"
        fi

        echo "Created zone file ${ZONE_FILE_PATH} → ${IP}"
        
        # reload BIND
        ${RNDC} reload
        echo "BIND reloaded."
        ;;

    remove)
        if [[ $# -ne 2 ]]; then
            usage
        fi

        remove_zone_stanza

        if [[ -f "${ZONE_FILE_PATH}" ]]; then
            rm -f "${ZONE_FILE_PATH}"
            echo "Deleted zone file ${ZONE_FILE_PATH}"
        else
            echo "No zone file ${ZONE_FILE_PATH} to delete"
        fi

        # full BIND reload to clear any hints
        ${RNDC} reload
        echo "BIND reloaded."
        ;;

    *)
        usage
        ;;
esac
