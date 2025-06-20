#!/usr/bin/env bash
#
# configure-dns.sh – add or remove BIND zones (supports wildcards)
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
  $0 add    <domain> <ip>     # add or overwrite a zone
  $0 remove <domain>          # remove a zone
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
DOMAIN=$2

# sanitize zone file name: replace '*' with '_wildcard'
ZONE_FILE_NAME="${DOMAIN//\*/_wildcard}.zone"
ZONE_FILE_PATH="${ZONE_DIR}/${ZONE_FILE_NAME}"

# remove existing zone stanza from named.conf.include
function remove_zone_stanza() {
    if grep -qE "^\s*zone\s+\"${DOMAIN}\"" "${CONFIG}"; then
        # delete from 'zone "<domain>" {' through the next '};'
        sed -i "/^\s*zone[[:space:]]\+\"${DOMAIN}\"/,/};/d" "${CONFIG}"
        echo "Removed zone stanza for ${DOMAIN} from ${CONFIG}"
    else
        echo "No existing zone stanza for ${DOMAIN} in ${CONFIG}"
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

zone "${DOMAIN}" {
    type master;
    file "${ZONE_FILE_NAME}";
};
EOF
        echo "Appended zone stanza for ${DOMAIN} to ${CONFIG}"

        # generate minimal zone file
        cat > "${ZONE_FILE_PATH}" <<EOF
\$TTL    86400
@       IN      SOA     ${DOMAIN}. root.${DOMAIN}. (
                            $(date +%Y%m%d%H%M) ; serial
                            3600             ; refresh
                            1800             ; retry
                            604800           ; expire
                            86400 )          ; minimum

        IN      NS      master.cm.cluster.
        IN      A       ${IP}
@       IN      A       ${IP}
EOF
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

        ${RNDC} reload
        echo "BIND reloaded."
        ;;

    *)
        usage
        ;;
esac
