# TrueNAS Scale 25.10+ Swap Configuration Guide

## Table of Contents

1. [Overview](#overview)
2. [The Problem](#the-problem)
3. [Why This Solution](#why-this-solution)
4. [Technical Background](#technical-background)
5. [Solution Architecture](#solution-architecture)
6. [Installation](#installation)
7. [Verification](#verification)
8. [Monitoring](#monitoring)
9. [Maintenance](#maintenance)
10. [Troubleshooting](#troubleshooting)
11. [References](#references)

---

## Overview

This guide provides a complete solution for configuring swap space on TrueNAS Scale 25.10.1 and newer versions where the GUI swap configuration option has been removed. The solution uses a ZFS zvol (volume) on the boot pool to provide fast, persistent swap space that survives reboots and system upgrades.

### Key Features

- ✅ **ZFS-native solution** using zvol (proper method for ZFS systems)
- ✅ **SSD-backed swap** for optimal performance
- ✅ **Systemd integration** for automatic activation on boot
- ✅ **Production-tested** and upgrade-safe
- ✅ **Prevents OOM kills** in Docker containers and applications

---

## The Problem

### Symptoms

Systems running TrueNAS Scale with Docker containers may experience:

1. **Out of Memory (OOM) kills** - Containers randomly crash with exit code 137
2. **High memory pressure** - System using 85-95% of available RAM
3. **Application instability** - Services like PostgreSQL, Immich, Jellyfin crashing under load
4. **No swap configured** - `swapon --show` returns empty
5. **GUI option removed** - TrueNAS 25.10+ removed the swap configuration from System → Advanced Settings

### Example Memory Pressure

```bash
$ free -h
               total        used        free      shared  buff/cache   available
Mem:            15Gi        14Gi       524Mi       541Mi       1.3Gi       838Mi
Swap:             0B          0B          0B
```

**Critical indicators:**
- 88% RAM utilization (14GB/16GB)
- Only 838MB available memory
- Zero swap space configured
- High risk of OOM kills

### Why No Swap is Dangerous

Without swap:
- Applications crash when they exceed available RAM
- No memory overflow protection
- Cannot handle temporary memory spikes
- Docker containers get OOM-killed during peak usage
- Database operations fail under load
- No graceful degradation path

---

## Why This Solution

### Decision Matrix

We evaluated several approaches:

| Approach | Pros | Cons | Verdict |
|----------|------|------|---------|
| **File-based swap on HDD** | Simple, large capacity | Very slow (spinning disks) | ❌ Not recommended |
| **File-based swap on SSD** | Fast storage | ZFS creates sparse files with "holes" | ❌ Doesn't work |
| **Zvol on HDD pool** | Large capacity | Slow swap performance | ❌ Not recommended |
| **Zvol on SSD boot pool** | Fast, ZFS-native, no holes | Uses boot pool space | ✅ **Best solution** |

### Why Zvol on Boot Pool?

#### Performance Considerations

**SSD vs HDD for swap:**
- **SSD (boot pool):** ~500 MB/s read/write, <1ms latency
- **HDD (data pool):** ~150 MB/s read/write, 10-15ms latency
- **Impact:** SSD swap is 3-5x faster with 10-15x lower latency

Swap is frequently accessed during memory pressure. Using HDDs would make the system feel sluggish and unresponsive. The boot pool SSD provides optimal performance.

#### Space Utilization

**Boot pool analysis:**
```bash
$ df -h /var
Filesystem                      Size  Used Avail Use% Mounted on
boot-pool/ROOT/25.10.1/var/lib   44G  219M   44G   1% /var/lib
```

- Boot pool total: ~50GB
- System usage: ~6GB
- Swap allocation: 8GB (16% of free space)
- Remaining: 36GB (adequate for system operations)

**Verdict:** Boot pool has plenty of space for 8GB swap while maintaining adequate headroom for TrueNAS operations.

#### ZFS Zvol Benefits

**Why zvol instead of a file:**

1. **No sparse file issues** - Block device doesn't have "holes"
2. **Native ZFS integration** - Proper ZFS volume management
3. **Better performance** - Block-level access, no filesystem overhead
4. **Atomic operations** - Consistent, crash-safe
5. **ZFS features** - Compression, checksums (though disabled for swap)

**Technical details:**
- Zvol appears as `/dev/zd0` (block device)
- Configured with swap-optimized ZFS properties
- No double-caching (metadata only)
- Zero-length encoding compression

---

## Technical Background

### Swap Size Calculation

**Industry guidelines:**

| RAM Size | Recommended Swap | Reasoning |
|----------|-----------------|-----------|
| < 2GB | 2x RAM | Need maximum overflow |
| 2-8GB | 1x RAM | Balanced approach |
| 8-16GB | 0.5-1x RAM | Moderate overflow needed |
| 16-64GB | 0.25-0.5x RAM | Minimal overflow needed |
| > 64GB | 4-8GB minimum | Emergency fallback only |

**For a 16GB RAM system:**
- Minimum: 4GB (25% of RAM)
- Recommended: 8GB (50% of RAM) ← **Our choice**
- Maximum: 16GB (100% of RAM)

**Why 8GB for this system:**
1. Current usage: 14GB/16GB (88% utilization)
2. Memory pressure: Only 838MB available
3. Docker workload: Memory-intensive containers
4. Boot pool space: 44GB free (8GB is only 18%)
5. Performance: More swap = more breathing room

### ZFS Zvol Properties

**Optimal swap configuration:**

```bash
zfs create -V 8G -b 16K \
    -o compression=zle \
    -o sync=always \
    -o primarycache=metadata \
    -o secondarycache=none \
    -o logbias=throughput \
    boot-pool/swap
```

**Property explanations:**

| Property | Value | Reasoning |
|----------|-------|-----------|
| `volblocksize` | 16K | Matches system page size, reduces overhead |
| `compression` | zle | Zero-length encoding only (minimal CPU) |
| `sync` | always | Synchronous writes for data integrity |
| `primarycache` | metadata | Don't cache swap data in ARC (avoid double-caching) |
| `secondarycache` | none | No L2ARC for swap (unnecessary) |
| `logbias` | throughput | Optimize for throughput over latency |

### Systemd Integration

**Why systemd over /etc/fstab:**

1. TrueNAS manages `/etc/fstab` - modifications may be lost
2. Systemd provides proper dependency management
3. Better integration with ZFS import process
4. Native support for swap devices
5. Survives TrueNAS upgrades

**Systemd swap unit structure:**

```ini
[Unit]
Description=Swap on ZFS zvol (boot pool)
After=zfs-import.target
Requires=zfs-import.target

[Swap]
What=/dev/zd0
Priority=-1

[Install]
WantedBy=swap.target
```

**Key components:**
- `After/Requires=zfs-import.target` - Wait for ZFS pools to import
- `What=/dev/zd0` - Swap device (zvol appears as block device)
- `Priority=-1` - Default swap priority
- `WantedBy=swap.target` - Automatically activate on boot

---

## Solution Architecture

### Component Overview

```
┌─────────────────────────────────────────────────┐
│           TrueNAS Scale System                  │
├─────────────────────────────────────────────────┤
│                                                 │
│  ┌──────────────┐         ┌-─────────────────┐  │
│  │  Boot Pool   │         │   Data Pool      │  │
│  │   (SSD)      │         │   (HDDs)         │  │
│  ├──────────────┤         └─-────────────────┘  │
│  │              │                               │
│  │ System: ~6GB │         Docker Containers     │
│  │              │         & Application Data    │
│  │ Swap: 8GB    │◄────────(Memory overflow)     │
│  │  (zvol)      │                               │
│  │              │                               │
│  │ Free: 36GB   │                               │
│  └──────────────┘                               │
│         ▲                                       │
│         │                                       │
│         └─── Fast SSD swap for performance      │
│                                                 │
└─────────────────────────────────────────────────┘
```

### Data Flow

1. **Normal operation:** Applications use RAM (14GB/16GB)
2. **Memory pressure:** Available RAM drops below threshold
3. **Swap activation:** Kernel moves inactive pages to swap
4. **Fast SSD access:** Zvol on boot pool provides quick swap I/O
5. **Graceful degradation:** System remains stable instead of OOM kills

### System Integration

```
Kernel Memory Manager
        │
        ├─► RAM (16GB) ──────┐
        │                    │
        └─► Swap (8GB)       │
              │              │
              └──────────────┴─► Application Memory Requests
                                 (Docker containers, services)
```

---

## Installation

### Prerequisites

- TrueNAS Scale 25.10.1 or newer
- Root/admin access to the system
- SSH enabled
- Boot pool with at least 10GB free space

### Pre-Installation Checks

```bash
# Check current memory status
free -h

# Check current swap status (should be empty)
swapon --show

# Check boot pool free space
zpool list boot-pool

# Check if swap zvol already exists
zfs list boot-pool/swap 2>/dev/null || echo "No existing swap zvol"
```

### Installation Script

Create the installation script:

```bash
cd /root
cat > configure-truenas-swap.sh << 'SCRIPT_EOF'
#!/bin/bash
#
# TrueNAS Scale 25.10+ Swap Configuration Script
# Creates an 8GB ZFS zvol on the boot pool for swap
#
# Usage: bash configure-truenas-swap.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
SWAP_SIZE_GB=8
ZVOL_NAME="boot-pool/swap"
ZVOL_DEVICE="/dev/zd0"
SYSTEMD_SERVICE="/etc/systemd/system/dev-zd0.swap"

# Helper functions
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

# Display system info
print_info "=== System Information ==="
TOTAL_RAM_GB=$(($(free -m | awk '/^Mem:/{print $2}') / 1024))
USED_RAM_GB=$(($(free -m | awk '/^Mem:/{print $3}') / 1024))
AVAIL_RAM_GB=$(($(free -m | awk '/^Mem:/{print $7}') / 1024))

echo "Total RAM: ${TOTAL_RAM_GB}GB"
echo "Used RAM: ${USED_RAM_GB}GB"
echo "Available RAM: ${AVAIL_RAM_GB}GB"
echo ""

# Check boot pool space
BOOT_POOL_AVAIL=$(zpool list boot-pool -H -o free | sed 's/G//' | cut -d'.' -f1)
echo "Boot Pool Available: ${BOOT_POOL_AVAIL}GB"
echo "Swap Size: ${SWAP_SIZE_GB}GB"
echo "Boot Pool After Swap: $((BOOT_POOL_AVAIL - SWAP_SIZE_GB))GB"
echo ""

# Verify sufficient space
if [[ $BOOT_POOL_AVAIL -lt $((SWAP_SIZE_GB + 10)) ]]; then
    print_error "Insufficient space on boot pool"
    print_error "Need at least $((SWAP_SIZE_GB + 10))GB free"
    exit 1
fi

# Check for existing zvol
if zfs list "${ZVOL_NAME}" >/dev/null 2>&1; then
    print_warn "Swap zvol already exists"
    print_info "To recreate, first run:"
    print_info "  swapoff ${ZVOL_DEVICE} 2>/dev/null || true"
    print_info "  zfs destroy ${ZVOL_NAME}"
    exit 1
fi

# Create ZFS volume
print_info "Creating ${SWAP_SIZE_GB}GB ZFS volume for swap..."
zfs create -V ${SWAP_SIZE_GB}G -b 16K \
    -o compression=zle \
    -o sync=always \
    -o primarycache=metadata \
    -o secondarycache=none \
    -o logbias=throughput \
    "${ZVOL_NAME}"

# Wait for device
print_info "Waiting for device to appear..."
sleep 3

# Verify device exists
if [[ ! -e "${ZVOL_DEVICE}" ]]; then
    print_error "Device ${ZVOL_DEVICE} not found"
    print_info "Available devices:"
    ls -la /dev/zd*
    exit 1
fi

# Setup swap
print_info "Formatting swap device..."
mkswap "${ZVOL_DEVICE}"

# Activate swap
print_info "Activating swap..."
swapon "${ZVOL_DEVICE}"

# Verify activation
if ! swapon --show | grep -q "${ZVOL_DEVICE}"; then
    print_error "Failed to activate swap"
    exit 1
fi

# Create systemd service
print_info "Creating systemd service for boot persistence..."
cat > "${SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=Swap on ZFS zvol (boot pool)
Documentation=man:swapon(8)
After=zfs-import.target
Requires=zfs-import.target

[Swap]
What=${ZVOL_DEVICE}
Priority=-1

[Install]
WantedBy=swap.target
EOF

# Enable service
systemctl daemon-reload
systemctl enable dev-zd0.swap

# Display results
echo ""
print_info "=== Installation Complete ==="
echo ""
echo "Swap Status:"
swapon --show
echo ""
echo "Memory Status:"
free -h
echo ""
echo "ZFS Volume:"
zfs list "${ZVOL_NAME}"
echo ""
print_info "✅ Swap successfully configured!"
print_info "Swap will automatically activate on reboot"
SCRIPT_EOF
```

### Execute Installation

```bash
# Make script executable
chmod +x configure-truenas-swap.sh

# Run the script
bash configure-truenas-swap.sh
```

### Expected Output

```
[INFO] === System Information ===
Total RAM: 15GB
Used RAM: 14GB
Available RAM: 1GB

Boot Pool Available: 45GB
Swap Size: 8GB
Boot Pool After Swap: 37GB

[INFO] Creating 8GB ZFS volume for swap...
[INFO] Waiting for device to appear...
[INFO] Formatting swap device...
Setting up swapspace version 1, size = 8 GiB (8589930496 bytes)
[INFO] Activating swap...
[INFO] Creating systemd service for boot persistence...
Created symlink /etc/systemd/system/swap.target.wants/dev-zd0.swap → /etc/systemd/system/dev-zd0.swap.

[INFO] === Installation Complete ===

Swap Status:
NAME     TYPE      SIZE USED PRIO
/dev/zd0 partition   8G   0B   -2

Memory Status:
               total        used        free      shared  buff/cache   available
Mem:            15Gi        14Gi       647Mi       530Mi       1.3Gi       1.1Gi
Swap:          8.0Gi          0B       8.0Gi

ZFS Volume:
NAME             USED  AVAIL  REFER  MOUNTPOINT
boot-pool/swap  8.50G  43.3G    56K  -

[INFO] ✅ Swap successfully configured!
[INFO] Swap will automatically activate on reboot
```

---

## Verification

### Immediate Verification

After installation, verify the configuration:

```bash
# 1. Check swap is active
swapon --show

# Expected output:
# NAME     TYPE      SIZE USED PRIO
# /dev/zd0 partition   8G   0B   -2

# 2. Check memory status
free -h

# Expected output shows Swap: 8.0Gi

# 3. Verify systemd service
systemctl status dev-zd0.swap

# Expected: Active: active since [timestamp]

# 4. Verify service is enabled for boot
systemctl is-enabled dev-zd0.swap

# Expected: enabled

# 5. Check ZFS volume
zfs list boot-pool/swap

# Expected: Shows 8.50G volume

# 6. Verify device
ls -la /dev/zd0

# Expected: Block device exists
```

### Reboot Persistence Test

**Important:** Test that swap survives a reboot:

```bash
# 1. Note current configuration
echo "Before reboot:"
swapon --show
free -h

# 2. Reboot the system
reboot

# 3. After reboot, verify swap is active
echo "After reboot:"
swapon --show
free -h
systemctl status dev-zd0.swap
```

**Expected result:** Swap automatically activates after reboot with the same configuration.

### TrueNAS Upgrade Verification

After any TrueNAS upgrade:

```bash
# Check if swap is still active
swapon --show

# If not active, reactivate
systemctl start dev-zd0.swap

# Verify service is still enabled
systemctl is-enabled dev-zd0.swap

# Re-enable if needed
systemctl enable dev-zd0.swap
```

---

## Monitoring

### Real-Time Monitoring

Monitor swap usage in real-time:

```bash
# Watch swap and memory status (updates every 2 seconds)
watch -n 2 'free -h && echo "" && swapon --show'
```

### Check Swap Usage

```bash
# Quick swap status
swapon --show

# Detailed memory breakdown
free -h

# Per-process swap usage (requires root)
for dir in /proc/*/; do
    pid=$(basename "$dir")
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        swap=$(grep VmSwap "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
        if [[ -n "$swap" && "$swap" != "0" ]]; then
            name=$(cat "/proc/$pid/comm" 2>/dev/null)
            echo "$swap kB - $name (PID: $pid)"
        fi
    fi
done | sort -n -r | head -20
```

### ZFS Volume Statistics

```bash
# Check ZFS volume usage
zfs list boot-pool/swap

# Detailed properties
zfs get all boot-pool/swap

# I/O statistics
zpool iostat boot-pool 1 10
```

### Historical Monitoring

Add to your monitoring stack (Netdata, Grafana, etc.):

**Metrics to track:**
- `mem.swap.total` - Total swap space
- `mem.swap.used` - Used swap space
- `mem.swap.free` - Free swap space
- `mem.available` - Available system memory
- `system.swapio` - Swap I/O operations

---

## Maintenance

### Regular Health Checks

**Monthly checks:**

```bash
# Verify swap is active and healthy
swapon --show
systemctl status dev-zd0.swap

# Check boot pool health
zpool status boot-pool

# Check space usage
zpool list boot-pool
zfs list boot-pool/swap
```

### Adjusting Swap Size

If you need to resize swap:

```bash
# 1. Deactivate swap
swapoff /dev/zd0

# 2. Destroy existing zvol
zfs destroy boot-pool/swap

# 3. Create new zvol with different size (e.g., 4GB)
zfs create -V 4G -b 16K \
    -o compression=zle \
    -o sync=always \
    -o primarycache=metadata \
    -o secondarycache=none \
    -o logbias=throughput \
    boot-pool/swap

# 4. Format and activate
mkswap /dev/zd0
swapon /dev/zd0

# 5. Verify
swapon --show
```

### Backup Configuration

Backup your swap configuration:

```bash
# Backup systemd service file
cp /etc/systemd/system/dev-zd0.swap /root/dev-zd0.swap.backup

# Document ZFS properties
zfs get all boot-pool/swap > /root/swap-zfs-properties.txt

# Backup this entire guide
# Keep this markdown file in /root/ or your documentation repo
```

### Removing Swap

If you need to remove swap completely:

```bash
# 1. Disable and stop service
systemctl stop dev-zd0.swap
systemctl disable dev-zd0.swap

# 2. Deactivate swap
swapoff /dev/zd0

# 3. Destroy ZFS volume
zfs destroy boot-pool/swap

# 4. Remove systemd service
rm /etc/systemd/system/dev-zd0.swap
systemctl daemon-reload

# 5. Verify removal
swapon --show  # Should be empty
zfs list boot-pool/swap  # Should error - not found
```

---

## Troubleshooting

### Swap Not Active After Reboot

**Symptoms:**
```bash
$ swapon --show
# (empty output)
```

**Solution:**
```bash
# Check if zvol exists
zfs list boot-pool/swap

# Check if device exists
ls -la /dev/zd0

# Manually start swap
systemctl start dev-zd0.swap

# Check for errors
systemctl status dev-zd0.swap
journalctl -u dev-zd0.swap -n 50

# Re-enable if disabled
systemctl enable dev-zd0.swap
```

### "Device or Resource Busy" Error

**Symptoms:**
```bash
$ swapon /dev/zd0
swapon: /dev/zd0: swapon failed: Device or resource busy
```

**Cause:** Swap is already active

**Solution:**
```bash
# Check current swap
swapon --show

# If already active, no action needed
# If you need to restart:
swapoff /dev/zd0
swapon /dev/zd0
```

### Zvol Has "Holes" Error

**Symptoms:**
```bash
swapon: /var/swap/swapfile: skipping - it appears to have holes
```

**Cause:** Using file-based swap instead of zvol

**Solution:**
This guide uses zvol (block device) which doesn't have this issue. If you see this error, you're using a file instead of a zvol. Follow the installation instructions above to create a proper zvol.

### High Swap Usage

**Symptoms:**
```bash
$ free -h
Swap:  8.0Gi       6.0Gi       2.0Gi
```

**Analysis:**
```bash
# Check which processes are using swap
for pid in /proc/[0-9]*; do
    swap=$(awk '/^VmSwap:/ {print $2}' $pid/status 2>/dev/null)
    if [ ! -z "$swap" ] && [ "$swap" -gt 0 ]; then
        name=$(cat $pid/comm 2>/dev/null)
        echo "$swap kB - $name - PID: $(basename $pid)"
    fi
done | sort -rn | head -20
```

**Solutions:**

1. **Add more RAM** - If consistently using >50% swap
2. **Optimize containers** - Add memory limits to Docker containers
3. **Reduce services** - Stop unnecessary containers
4. **Investigate memory leaks** - Check logs for problematic services

### Systemd Service Won't Start

**Symptoms:**
```bash
$ systemctl start dev-zd0.swap
Job for dev-zd0.swap failed.
```

**Diagnosis:**
```bash
# Check detailed error
systemctl status dev-zd0.swap
journalctl -xe | grep -A 20 swap

# Verify device exists
ls -la /dev/zd0

# Check ZFS volume
zfs list boot-pool/swap

# Verify service file
cat /etc/systemd/system/dev-zd0.swap
```

**Common fixes:**

1. **Device doesn't exist:**
   ```bash
   # Reimport ZFS pools
   zpool import -a
   
   # Wait for device
   sleep 3
   udevadm settle
   ```

2. **Service file corrupted:**
   ```bash
   # Recreate service file (see installation section)
   systemctl daemon-reload
   systemctl enable dev-zd0.swap
   ```

3. **Rate limit hit:**
   ```bash
   # Reset failed state
   systemctl reset-failed dev-zd0.swap
   
   # Wait 30 seconds
   sleep 30
   
   # Try again
   systemctl start dev-zd0.swap
   ```

### Boot Pool Running Out of Space

**Symptoms:**
```bash
$ zpool list boot-pool
NAME        SIZE  ALLOC   FREE
boot-pool  44.5G  40.1G  4.4G
```

**Solutions:**

1. **Reduce swap size** (if possible):
   ```bash
   # Follow "Adjusting Swap Size" in Maintenance section
   # Reduce from 8GB to 4GB
   ```

2. **Clean up system logs:**
   ```bash
   journalctl --vacuum-size=100M
   ```

3. **Remove old boot environments:**
   ```bash
   # List boot environments
   zfs list -r boot-pool/ROOT
   
   # Remove old ones (keep at least 2)
   zfs destroy boot-pool/ROOT/old-version
   ```

### Performance Issues

**Symptoms:**
- System feels slow
- High I/O wait times
- Frequent swap activity

**Diagnosis:**
```bash
# Check swap I/O
iostat -x 2 10 | grep zd0

# Check overall system I/O
iotop -ao

# Monitor in real-time
watch -n 1 'iostat -x 1 1 | grep zd0'
```

**Solutions:**

1. **Add more RAM** - Primary solution for swap performance issues
2. **Optimize applications** - Reduce memory usage in containers
3. **Check for memory leaks** - Investigate high-memory processes
4. **Increase swappiness** (if needed):
   ```bash
   # Check current swappiness
   cat /proc/sys/vm/swappiness
   
   # Temporarily adjust (default is 60)
   sysctl vm.swappiness=10
   
   # Make permanent
   echo "vm.swappiness=10" >> /etc/sysctl.conf
   ```

---

## References

### Official Documentation

- [TrueNAS Scale Documentation](https://www.truenas.com/docs/scale/)
- [ZFS Administration Guide](https://openzfs.github.io/openzfs-docs/)
- [Systemd Swap Documentation](https://www.freedesktop.org/software/systemd/man/systemd.swap.html)
- [Linux Kernel Swap Documentation](https://www.kernel.org/doc/html/latest/admin-guide/mm/concepts.html)

### Related Articles

- [ZFS on Linux - Swap Configuration](https://openzfs.github.io/openzfs-docs/Performance%20and%20Tuning/Workload%20Tuning.html)
- [Red Hat - Memory Management](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/managing_monitoring_and_updating_the_kernel/configuring-kernel-command-line-parameters_managing-monitoring-and-updating-the-kernel)
- [Arch Linux Wiki - Swap](https://wiki.archlinux.org/title/swap)

### Community Resources

- [TrueNAS Community Forums](https://www.truenas.com/community/)
- [r/truenas on Reddit](https://www.reddit.com/r/truenas/)
- [TrueNAS Discord](https://discord.gg/Q3St5fPETd)

### Technical Background

- [Understanding Linux Memory Management](https://www.kernel.org/doc/html/latest/admin-guide/mm/index.html)
- [ZFS Performance Tuning](https://openzfs.github.io/openzfs-docs/Performance%20and%20Tuning/index.html)
- [Systemd Unit Files](https://www.freedesktop.org/software/systemd/man/systemd.unit.html)

---

## Credits and License

**Author:** Created for TrueNAS Scale 25.10.1+ deployments

**Tested on:**
- TrueNAS Scale 25.10.1
- 16GB RAM system with Docker containers
- Intel Core i3-2310M processor

**License:** MIT License - Feel free to use, modify, and distribute

**Contributing:**
- Issues and improvements welcome via GitHub issues
- Pull requests accepted for corrections and enhancements
- Share your experiences and findings

---

## Changelog

### Version 1.0 (2026-01-17)
- Initial release
- Covers TrueNAS Scale 25.10.1+
- Complete installation and troubleshooting guide
- Tested and verified on production system

---

## Appendix: Quick Reference

### Essential Commands

```bash
# Check swap status
swapon --show

# Check memory
free -h

# Check ZFS volume
zfs list boot-pool/swap

# Check systemd service
systemctl status dev-zd0.swap

# View swap I/O
iostat -x 2 5 | grep zd0

# Monitor real-time
watch -n 2 'free -h && echo "" && swapon --show'
```

### Service Management

```bash
# Start swap
systemctl start dev-zd0.swap

# Stop swap
systemctl stop dev-zd0.swap

# Enable on boot
systemctl enable dev-zd0.swap

# Disable on boot
systemctl disable dev-zd0.swap

# Restart swap
systemctl restart dev-zd0.swap

# Check status
systemctl status dev-zd0.swap
```

### Emergency Recovery

```bash
# If swap is not working at all:

# 1. Check if zvol exists
zfs list boot-pool/swap

# 2. If zvol exists but device missing
udevadm trigger
udevadm settle
ls -la /dev/zd*

# 3. Manually activate
swapon /dev/zd0

# 4. Fix systemd
systemctl reset-failed dev-zd0.swap
systemctl start dev-zd0.swap

# 5. If all else fails, reinstall
swapoff /dev/zd0 2>/dev/null || true
zfs destroy boot-pool/swap
# Then re-run installation script
```

### Configuration Files

**Systemd service:** `/etc/systemd/system/dev-zd0.swap`

```ini
[Unit]
Description=Swap on ZFS zvol (boot pool)
Documentation=man:swapon(8)
After=zfs-import.target
Requires=zfs-import.target

[Swap]
What=/dev/zd0
Priority=-1

[Install]
WantedBy=swap.target
```

**ZFS properties:**
```bash
zfs get all boot-pool/swap | grep -v "inherit\|default"
```

---

**End of Guide**

For questions, issues, or improvements, please open an issue on GitHub.
