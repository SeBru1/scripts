#!/bin/bash
# Create a minimal Debian LXC on Proxmox and install Newt agent
#
# Usage: bash create-newt-lxc.sh
#
# Run this on the Proxmox host. It will:
# 1. Create a privileged Debian LXC (minimal resources)
# 2. Install dependencies
# 3. Launch the Newt service manager (interactive setup)

set -euo pipefail

# --- Defaults (override via env vars) ---
HOSTNAME="${HOSTNAME:-newt-mfh}"
BRIDGE="${BRIDGE:-vmbr0}"
MEMORY="${MEMORY:-128}"
DISK="${DISK:-2}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Checks ---
command -v pct >/dev/null 2>&1 || error "This script must run on a Proxmox host."
[[ $EUID -eq 0 ]] || error "Run as root."

# --- Get next CTID ---
CTID=$(pvesh get /cluster/nextid)
info "Using CTID: $CTID"

# --- Prompt for settings ---
read -rp "Hostname [$HOSTNAME]: " input
HOSTNAME="${input:-$HOSTNAME}"

read -rp "Network bridge [$BRIDGE]: " input
BRIDGE="${input:-$BRIDGE}"

read -rp "VLAN tag (leave empty for none): " VLAN
NET_CONFIG="name=eth0,bridge=${BRIDGE},ip=dhcp"
[[ -n "$VLAN" ]] && NET_CONFIG="${NET_CONFIG},tag=${VLAN}"

# --- Download Debian template if missing ---
TEMPLATE=$(pveam available --section system | grep 'debian-12-standard' | tail -1 | awk '{print $2}')
[[ -z "$TEMPLATE" ]] && error "No Debian 12 template found. Run: pveam update"

if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
    info "Downloading $TEMPLATE ..."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
else
    info "Template $TEMPLATE already available."
fi

# --- Create LXC ---
info "Creating LXC $CTID ($HOSTNAME) ..."
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME" \
    --memory "$MEMORY" \
    --swap 0 \
    --cores 1 \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "$NET_CONFIG" \
    --unprivileged 0 \
    --features nesting=1 \
    --onboot 1 \
    --start 0

info "LXC $CTID created."

# --- Start ---
info "Starting LXC $CTID ..."
pct start "$CTID"
sleep 5

# --- Wait for network ---
info "Waiting for network ..."
for i in $(seq 1 30); do
    if pct exec "$CTID" -- ping -c1 -W1 github.com >/dev/null 2>&1; then
        info "Network ready."
        break
    fi
    [[ $i -eq 30 ]] && error "Network not available after 30s."
    sleep 1
done

# --- Install dependencies ---
info "Installing dependencies ..."
pct exec "$CTID" -- bash -c "
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates > /dev/null 2>&1
"

# --- Launch Newt Service Manager ---
info "Launching Newt Service Manager ..."
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Newt Service Manager (interactive setup)  ${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "  Endpoint: ${YELLOW}https://tunnel.brunk.cloud${NC}"
echo -e "  Get Newt ID + Secret from Pangolin UI"
echo ""

pct exec "$CTID" -- bash -c "curl -sL https://raw.githubusercontent.com/dpurnam/scripts/main/newt/newt-service-manager.sh | bash"

echo ""
info "Done! LXC $CTID ($HOSTNAME) is running with Newt agent."
info "Manage: pct enter $CTID"
