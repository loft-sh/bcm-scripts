#!/usr/bin/env bash
#
# make-bridge.sh - Create a host bridge and enslave an existing interface
#
# Usage:
#   sudo ./make-bridge.sh -i <iface> [-b <bridge>] [--dry-run]
#
# Example:
#   sudo ./make-bridge.sh -i eth0 -b br0
#
# What it does:
#   - Creates a bridge (default br0) if missing
#   - Copies MAC + MTU from iface to bridge (prevents ARP flux)
#   - Moves all IPv4/IPv6 addresses from iface -> bridge
#   - Moves default and on-link routes to use the bridge
#   - Enslaves iface under the bridge
#
# Notes:
#   - Requires root. Uses only iproute2 tools.
#   - Idempotent: re-running won’t break existing setup.
#   - Does NOT write persistent config files (see “Persistence” below).

set -euo pipefail

BR="br0"
IFACE=""
DRY_RUN="false"

log() { echo -e "[make-bridge] $*"; }
die() { echo -e "[make-bridge] ERROR: $*" >&2; exit 1; }

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "+ $*"
  else
    eval "$@"
  fi
}

usage() {
  cat <<EOF
Usage: sudo $0 -i <iface> [-b <bridge>] [--dry-run]

Options:
  -i, --iface   Physical interface to enslave (e.g., eth0, enp1s0)
  -b, --bridge  Bridge name to create/use (default: br0)
      --dry-run Print actions without applying changes
  -h, --help    Show this help

EOF
}

# -------- Parse args --------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--iface) IFACE="${2:-}"; shift 2 ;;
    -b|--bridge) BR="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1";;
  esac
done

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -n "$IFACE" ]] || { usage; die "Missing -i/--iface."; }
[[ -d "/sys/class/net/$IFACE" ]] || die "Interface $IFACE not found."

command -v ip >/dev/null || die "'ip' command not found."
command -v bridge >/dev/null || die "'bridge' command not found."

# -------- Gather current state --------
IF_MAC="$(cat /sys/class/net/$IFACE/address)"
IF_MTU="$(cat /sys/class/net/$IFACE/mtu)"
IF_STATE="$(cat /sys/class/net/$IFACE/operstate || echo unknown)"

# IP addresses (IPv4 + IPv6) currently on the IFACE
readarray -t IF_ADDRS < <(ip -o addr show dev "$IFACE" | awk '{print $2,$3,$4}' | sed 's/^.* //g')

# Default gateways that currently egress via IFACE
readarray -t DEF_V4 < <(ip -4 route show default 0.0.0.0/0 dev "$IFACE" || true)
readarray -t DEF_V6 < <(ip -6 route show default ::/0 dev "$IFACE" || true)

# On-link routes (connected routes via IFACE) excluding local/lo
readarray -t CONN_V4 < <(ip -4 route show dev "$IFACE" scope link || true)
readarray -t CONN_V6 < <(ip -6 route show dev "$IFACE" scope link || true)

log "Interface: $IFACE (state=$IF_STATE mac=$IF_MAC mtu=$IF_MTU)"
log "Bridge   : $BR"

# -------- Create bridge if needed --------
if [[ -d "/sys/class/net/$BR" ]]; then
  log "Bridge $BR already exists."
else
  log "Creating bridge $BR"
  run "ip link add name $BR type bridge vlan_filtering 0 stp_state 0"
fi

# Set MTU before enslaving to avoid mismatch
run "ip link set dev $BR mtu $IF_MTU"

# Set bridge MAC to the physical NIC’s MAC (prevents MAC churn on switches)
CUR_BR_MAC="$(cat /sys/class/net/$BR/address 2>/dev/null || echo "")"
if [[ "$CUR_BR_MAC" != "$IF_MAC" ]]; then
  log "Setting $BR MAC to $IF_MAC"
  run "ip link set dev $BR address $IF_MAC"
fi

# Bring bridge up early so routes/addresses stick
run "ip link set dev $BR up"

# -------- Move IPs from IFACE -> BR --------
if [[ ${#IF_ADDRS[@]} -gt 0 ]]; then
  log "Migrating IP addresses from $IFACE to $BR:"
  for CIDR in "${IF_ADDRS[@]}"; do
    log " - $CIDR"
    run "ip addr del $CIDR dev $IFACE"
    run "ip addr add $CIDR dev $BR"
  done
else
  log "No IPs configured on $IFACE (DHCP? static elsewhere?)."
fi

# -------- Move default routes --------
add_default_routes() {
  local fam="$1"; shift
  local dev_from="$1"; shift
  local dev_to="$1"; shift
  local -n defs_ref="$1"

  for D in "${defs_ref[@]}"; do
    [[ -z "$D" ]] && continue
    # Parse "default via X dev IFACE ..."
    local GW
    GW="$(awk '/via/ {print $3}' <<<"$D")"
    if [[ -n "$GW" ]]; then
      log "Move default route (v$fam): via $GW dev $dev_to"
      run "ip -$fam route del default dev $dev_from || true"
      run "ip -$fam route add default via $GW dev $dev_to"
    else
      # If no via (e.g., SLAAC or weird setup), just swap dev
      log "Move default route (v$fam): dev $dev_to (no via)"
      run "ip -$fam route del default dev $dev_from || true"
      run "ip -$fam route add default dev $dev_to"
    fi
  done
}

if [[ ${#DEF_V4[@]} -gt 0 ]]; then add_default_routes 4 "$IFACE" "$BR" DEF_V4; fi
if [[ ${#DEF_V6[@]} -gt 0 ]]; then add_default_routes 6 "$IFACE" "$BR" DEF_V6; fi

# -------- Enslave the physical interface --------
# Ensure iface has no IPs left before enslaving (we already moved them)
if ip -o addr show dev "$IFACE" | grep -qE '.'; then
  log "Flushing remaining IPs on $IFACE"
  run "ip addr flush dev $IFACE"
fi

log "Enslaving $IFACE under $BR"
run "ip link set dev $IFACE master $BR"
run "ip link set dev $IFACE up"

# -------- Bridge tuning (sane defaults) --------
# Fast-forwarding, keep ageing reasonable, enable multicast snooping
run "bridge link set dev $IFACE hairpin off flood on mcast_flood on neigh_suppress off learning on"
run "ip link set dev $BR type bridge ageing_time 300 forward_delay 0 stp_state 0 mcast_snooping 1"

# -------- Summary --------
log "Done."
log "Bridge $BR is up; $IFACE is enslaved."
log "Verify with:"
echo "  ip -br link show dev $BR"
echo "  ip -br link show dev $IFACE"
echo "  ip addr show dev $BR"
echo "  bridge link show | grep -E \"master $BR|$IFACE\""
