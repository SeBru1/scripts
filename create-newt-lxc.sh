#!/bin/bash
# Create a minimal Debian LXC on Proxmox and install Newt (Pangolin) agent
#
# Usage: bash create-newt-lxc.sh
#
# Run this on the Proxmox host. It will:
# 1. Create a privileged Debian LXC (minimal resources)
# 2. Install dependencies
# 3. Launch the Newt service manager (interactive setup)

set -euo pipefail

# --- Defaults ---
DEFAULT_HOSTNAME="newt"
DEFAULT_MEMORY=128
DEFAULT_DISK=2

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Helper: present a numbered list and return the selection
pick_one() {
    local prompt="$1"
    shift
    local options=("$@")
    echo ""
    echo -e "${CYAN}${prompt}${NC}"
    for i in "${!options[@]}"; do
        echo "  $((i+1))) ${options[$i]}"
    done
    while true; do
        read -rp "Choice [1]: " choice
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            PICKED="${options[$((choice-1))]}"
            return
        fi
        echo "  Invalid choice."
    done
}

# --- Checks ---
command -v pct >/dev/null 2>&1 || error "This script must run on a Proxmox host."
[[ $EUID -eq 0 ]] || error "Run as root."

# --- Get next CTID ---
CTID=$(pvesh get /cluster/nextid)
info "Using CTID: $CTID"

# --- Hostname ---
read -rp "Hostname [$DEFAULT_HOSTNAME]: " input
HOSTNAME="${input:-$DEFAULT_HOSTNAME}"

# --- Storage selection (for rootfs) ---
mapfile -t STORAGES < <(pvesm status --content rootdir 2>/dev/null | tail -n+2 | awk '{print $1}')
[[ ${#STORAGES[@]} -eq 0 ]] && error "No storage with 'rootdir' content found."
if [[ ${#STORAGES[@]} -eq 1 ]]; then
    STORAGE="${STORAGES[0]}"
    info "Using storage: $STORAGE"
else
    pick_one "Select storage for rootfs:" "${STORAGES[@]}"
    STORAGE="$PICKED"
fi

# --- Template storage selection ---
mapfile -t TMPL_STORAGES < <(pvesm status --content vztmpl 2>/dev/null | tail -n+2 | awk '{print $1}')
[[ ${#TMPL_STORAGES[@]} -eq 0 ]] && error "No storage with 'vztmpl' content found."
if [[ ${#TMPL_STORAGES[@]} -eq 1 ]]; then
    TEMPLATE_STORAGE="${TMPL_STORAGES[0]}"
else
    pick_one "Select storage for templates:" "${TMPL_STORAGES[@]}"
    TEMPLATE_STORAGE="$PICKED"
fi

# --- Network bridge selection ---
mapfile -t BRIDGES < <(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}')
[[ ${#BRIDGES[@]} -eq 0 ]] && BRIDGES=("vmbr0")
if [[ ${#BRIDGES[@]} -eq 1 ]]; then
    BRIDGE="${BRIDGES[0]}"
    info "Using bridge: $BRIDGE"
else
    pick_one "Select network bridge:" "${BRIDGES[@]}"
    BRIDGE="$PICKED"
fi

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

# --- Summary ---
echo ""
echo -e "${CYAN}=== LXC Summary ===${NC}"
echo "  CTID:     $CTID"
echo "  Hostname: $HOSTNAME"
echo "  Storage:  $STORAGE (${DEFAULT_DISK}G)"
echo "  Memory:   ${DEFAULT_MEMORY}MB"
echo "  Network:  $BRIDGE${VLAN:+ (VLAN $VLAN)}"
echo ""
read -rp "Create LXC? [Y/n]: " confirm
[[ "${confirm,,}" == "n" ]] && { echo "Aborted."; exit 0; }

# --- Create LXC ---
info "Creating LXC $CTID ($HOSTNAME) ..."
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME" \
    --memory "$DEFAULT_MEMORY" \
    --swap 0 \
    --cores 1 \
    --rootfs "${STORAGE}:${DEFAULT_DISK}" \
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
echo -e "  You will need: Newt ID, Secret, and Pangolin endpoint URL"
echo -e "  Get these from your Pangolin dashboard."
echo ""

pct exec "$CTID" -- bash -c "curl -sL https://raw.githubusercontent.com/dpurnam/scripts/main/newt/newt-service-manager.sh | bash"

echo ""
info "Done! LXC $CTID ($HOSTNAME) is running with Newt agent."
info "Manage: pct enter $CTID"
