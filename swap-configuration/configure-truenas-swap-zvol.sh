#!/bin/bash
#
# TrueNAS 25.10.1 Swap Configuration Script - SSD Boot Pool Version
# This script creates a swap file on the SSD boot pool for optimal performance
#
# IMPORTANT: This script is designed for TrueNAS 25.10.1+ where GUI swap options were removed
# It creates a 4GB swap file on the boot pool (SSD) for fast swap performance
# Size is conservative to avoid filling the boot pool
#
# Usage: bash configure-truenas-swap.sh
#
# System Info:
# - RAM: 16GB (14GB used, only 838MB available - CRITICAL)
# - Boot Pool: 44GB free on SSD (fast)
# - Swap Size: 8GB (50% of RAM, industry standard for high memory usage systems)

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Swap configuration - using boot pool for SSD performance
# 8GB = 50% of 16GB RAM (optimal for systems with high memory usage)
SWAP_SIZE_GB=8
SWAP_PATH="/var/swap"
SWAP_FILE="${SWAP_PATH}/swapfile"
SYSTEMD_SWAP_SERVICE="/etc/systemd/system/var-swap-swapfile.swap"

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

# Display system info
print_info "=== System Information ==="
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
USED_RAM_MB=$(free -m | awk '/^Mem:/{print $3}')
AVAIL_RAM_MB=$(free -m | awk '/^Mem:/{print $7}')
TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))
USED_RAM_GB=$((USED_RAM_MB / 1024))
AVAIL_RAM_GB=$((AVAIL_RAM_MB / 1024))

echo "Total RAM: ${TOTAL_RAM_GB}GB"
echo "Used RAM: ${USED_RAM_GB}GB"
echo "Available RAM: ${AVAIL_RAM_GB}GB"
echo ""

# Check boot pool space
BOOT_POOL_AVAIL=$(df -BG /var | awk 'NR==2 {print $4}' | sed 's/G//')
echo "Boot Pool Available: ${BOOT_POOL_AVAIL}GB"
echo "Swap Size: ${SWAP_SIZE_GB}GB"
echo "Boot Pool After Swap: $((BOOT_POOL_AVAIL - SWAP_SIZE_GB))GB"
echo ""

# Verify we have enough space
if [[ $BOOT_POOL_AVAIL -lt $((SWAP_SIZE_GB + 10)) ]]; then
    print_error "Insufficient space on boot pool. Need at least $((SWAP_SIZE_GB + 10))GB free."
    print_error "Current available: ${BOOT_POOL_AVAIL}GB"
    exit 1
fi

print_info "Creating ${SWAP_SIZE_GB}GB swap file on SSD boot pool at ${SWAP_FILE}"

# Check if swap directory exists
if [[ ! -d "${SWAP_PATH}" ]]; then
    print_info "Creating swap directory: ${SWAP_PATH}"
    mkdir -p "${SWAP_PATH}"
fi

# Check if swap file already exists
if [[ -f "${SWAP_FILE}" ]]; then
    print_warn "Swap file already exists. Checking if it's active..."
    if swapon --show | grep -q "${SWAP_FILE}"; then
        print_warn "Swap file is currently active. Deactivating..."
        swapoff "${SWAP_FILE}"
    fi
    print_info "Removing existing swap file"
    rm -f "${SWAP_FILE}"
fi

# Create swap file with proper permissions
print_info "Creating swap file (this may take a minute)..."
dd if=/dev/zero of="${SWAP_FILE}" bs=1G count="${SWAP_SIZE_GB}" status=progress
chmod 600 "${SWAP_FILE}"

# Setup swap
print_info "Setting up swap..."
mkswap "${SWAP_FILE}"

# Activate swap
print_info "Activating swap..."
swapon "${SWAP_FILE}"

# Verify swap is active
if swapon --show | grep -q "${SWAP_FILE}"; then
    print_info "Swap successfully activated"
    swapon --show
else
    print_error "Failed to activate swap"
    exit 1
fi

# Create systemd swap unit
print_info "Creating systemd swap unit for persistence across reboots..."
cat > "${SYSTEMD_SWAP_SERVICE}" <<EOF
[Unit]
Description=Swap file on SSD boot pool
Documentation=man:swapon(8)
After=local-fs.target

[Swap]
What=${SWAP_FILE}
Priority=1

[Install]
WantedBy=swap.target
EOF

# Reload systemd daemon
print_info "Reloading systemd daemon..."
systemctl daemon-reload

# Enable the swap service
print_info "Enabling swap service to start on boot..."
systemctl enable var-swap-swapfile.swap

# Display current swap status
echo ""
print_info "=== Current System Status ==="
free -h
echo ""
swapon --show

# Display summary
echo ""
print_info "=== Configuration Summary ==="
echo "Total RAM: ${TOTAL_RAM_GB}GB"
echo "Swap Size: ${SWAP_SIZE_GB}GB"
echo "Swap Location: ${SWAP_FILE} (SSD)"
echo "Boot Pool Remaining: $((BOOT_POOL_AVAIL - SWAP_SIZE_GB))GB"
echo ""

print_info "✅ Swap configuration complete!"
print_info "The swap file will be automatically activated on reboot."
echo ""
print_warn "IMPORTANT NOTES:"
print_warn "1. After TrueNAS upgrades, verify swap is active: swapon --show"
print_warn "2. If inactive after upgrade, restart it: systemctl start var-swap-swapfile.swap"
print_warn "3. Boot pool usage will increase by ${SWAP_SIZE_GB}GB"
print_warn "4. Monitor boot pool space: df -h /var"
echo ""
print_info "Your system was under heavy memory pressure (14GB/16GB used)"
print_info "This ${SWAP_SIZE_GB}GB swap will prevent OOM kills in Docker containers"
