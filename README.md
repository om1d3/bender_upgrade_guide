# TrueNAS SCALE Upgrade Guide for HP MicroServer Gen8

## Overview

This guide documents the process of upgrading TrueNAS SCALE on an HP MicroServer Gen8 with a custom boot configuration. The server uses a MicroSD card with GRUB in the MBR to chainload to an SSD on the ODD SATA port, which the BIOS cannot directly boot from.

## Hardware Configuration

- **Server**: HP MicroServer Gen8
- **Hostname**: bender
- **Boot Device**: MicroSD card (~60GB) with GRUB MBR
- **System Drive**: SSD on ODD SATA port (not BIOS-bootable)
- **Data Pool**: 4x 18TB WD drives in RAIDZ1 named "BIG"

## Boot Chain

1. BIOS boots from MicroSD MBR (only bootable device BIOS recognizes)
2. MicroSD GRUB chainloads to SSD on ODD SATA port
3. SSD contains actual TrueNAS installation

## The Problem

When TrueNAS updates:
- It creates a new boot environment (e.g., `ROOT/25.10.1`)
- It updates GRUB on the SSD
- It does NOT update the MicroSD GRUB config
- MicroSD GRUB still references old boot environment → boot fails

## Pre-Upgrade Steps

### 1. Identify Your MicroSD Device

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL,TRAN
```

Look for the MicroSD card - in this case it was `sde` (59.5GB, "Internal SD-CARD").

### 2. Backup Current MicroSD GRUB Config

```bash
mkdir -p /mnt/microsd
mount /dev/sde1 /mnt/microsd
cp /mnt/microsd/boot/grub/grub.cfg ~/grub-microsd-backup-$(date +%Y%m%d).cfg
umount /mnt/microsd
```

### 3. Download TrueNAS Configuration

Via Web UI:
- **System** → **General** → **Manage Configuration** → **Download File**

### 4. Save Pool Metadata (Optional but Recommended)

```bash
zpool status BIG > ~/pool-status-backup.txt
zfs list -r BIG > ~/datasets-backup.txt
zpool get all BIG > ~/pool-properties-backup.txt

# Copy these to your local machine
scp root@bender:~/*backup.txt .
```

### 5. Verify iLO/Console Access

Ensure you have working HP iLO access as you'll need it after reboot.

## Upgrade Process

### Step 1: Apply the Update

Via Web UI:
1. Go to **System** → **Update**
2. Click **Download Updates** (if not already downloaded)
3. Click **Apply Pending Update**
4. System will install and automatically reboot
5. **Boot will fail** (this is expected)

### Step 2: Manual Boot via iLO Console

When GRUB menu appears (showing old version "TrueNAS Scale GNU/Linux 24.04.2"):

1. **Press `e`** to edit the boot entry
2. **Locate and modify** these lines:

Find:
```
linux /ROOT/24.04.2@/boot/vmlinuz-6.6.32-production+truenas root=ZFS=boot-pool/ROOT/24.04.2 ...
```

Change to:
```
linux /ROOT/25.10.1@/boot/vmlinuz-6.12.33-production+truenas root=ZFS=boot-pool/ROOT/25.10.1 ...
```

Find:
```
initrd /ROOT/24.04.2@/boot/initrd.img-6.6.32-production+truenas
```

Change to:
```
initrd /ROOT/25.10.1@/boot/initrd.img-6.12.33-production+truenas
```

3. **Press `Ctrl+X`** or `F10` to boot

### Step 3: Permanently Fix MicroSD GRUB

Once the system boots successfully:

**IMPORTANT**: Device names may have changed after reboot. Find your MicroSD:

```bash
# Check current device mapping
lsblk -o NAME,SIZE,TYPE,FSTYPE

# Find the ext4 partition (~128M)
blkid | grep ext4 | grep -v boot-pool
```

In our case, the MicroSD shifted from `sde1` to `sdf1` after reboot.

Mount and fix the configuration:

```bash
# Mount MicroSD (was sdf1 after reboot)
mount /dev/sdf1 /mnt/microsd

# Backup current config
cp /mnt/microsd/boot/grub/grub.cfg /mnt/microsd/boot/grub/grub.cfg.bak

# Update all references automatically
sed -i 's/24\.04\.2/25.10.1/g; s/6\.6\.32/6.12.33/g' /mnt/microsd/boot/grub/grub.cfg

# Verify changes
grep "25.10.1" /mnt/microsd/boot/grub/grub.cfg | head -3

# Should show:
# menuentry 'TrueNAS Scale GNU/Linux 25.10.1' ...
# linux /ROOT/25.10.1@/boot/vmlinuz-6.12.33-production+truenas root=ZFS=boot-pool/ROOT/25.10.1 ...
# initrd /ROOT/25.10.1@/boot/initrd.img-6.12.33-production+truenas

# Sync and unmount
sync
umount /mnt/microsd
```

### Step 4: Test Automatic Boot

```bash
reboot
```

System should now boot automatically without manual intervention.

### Step 5: Verify Upgrade

After successful boot:

```bash
# Check version
cat /etc/version  # Should show: TrueNAS-SCALE-25.10.1

# Check kernel
uname -r  # Should show: 6.12.33-production+truenas

# Verify pool health
zpool status BIG

# Check boot environments
zfs list -r boot-pool/ROOT
```

## Version-Specific Details

### Dragonfish 24.04.2 → Goldeye 25.10.1

- **Old Kernel**: 6.6.32-production+truenas
- **New Kernel**: 6.12.33-production+truenas
- **Old Boot Environment**: ROOT/24.04.2
- **New Boot Environment**: ROOT/25.10.1

## Troubleshooting

### Boot Fails After Update

**Symptom**: System doesn't boot after update
**Solution**: Use iLO console to manually edit GRUB (Step 2 above)

### Can't Find MicroSD After Reboot

**Symptom**: Device names changed, can't find MicroSD
**Solution**: 
```bash
lsblk -o NAME,SIZE,FSTYPE
blkid | grep ext4
```
Look for the small (~128M) ext4 partition.

### Wrong Kernel Version

**Symptom**: Kernel version in GRUB doesn't match
**Solution**: Check actual kernel version on SSD:
```bash
ls /boot/ROOT/25.10.1@/boot/vmlinuz-*
```
Use the exact filename shown.

### Pool Won't Import

**Symptom**: BIG pool doesn't show up after upgrade
**Solution**:
```bash
# Manually import pool
zpool import BIG

# Or if that fails, list importable pools
zpool import
```

## Important Notes

- **No need to run `update-grub`** - you're only editing the config file, not reinstalling GRUB
- **Device names (`/dev/sdX`) may change** between reboots, but ZFS uses UUIDs so pools remain accessible
- **Your data pool is separate** from the boot device and won't be touched during upgrade
- **Keep the old boot environment** - don't delete ROOT/24.04.2 until you've verified 25.10.1 is stable

## Future Upgrades

For future TrueNAS upgrades, repeat this process:

1. Apply update via web UI
2. Boot fails (expected)
3. Manual boot via iLO console with new version numbers
4. Fix MicroSD GRUB with new paths
5. Reboot to verify

## Automation Script

For future upgrades, you can create a script to automate the MicroSD GRUB fix. Save this as `fix-microsd-grub.sh`:

```bash
#!/bin/bash

OLD_VERSION="$1"
NEW_VERSION="$2"
OLD_KERNEL="$3"
NEW_KERNEL="$4"

if [ -z "$4" ]; then
    echo "Usage: $0 OLD_VERSION NEW_VERSION OLD_KERNEL NEW_KERNEL"
    echo "Example: $0 24.04.2 25.10.1 6.6.32 6.12.33"
    exit 1
fi

# Find MicroSD (look for small ext4 partition)
MICROSD=$(blkid | grep ext4 | grep -v boot-pool | head -1 | cut -d: -f1)

if [ -z "$MICROSD" ]; then
    echo "Error: Could not find MicroSD device"
    exit 1
fi

echo "Found MicroSD: $MICROSD"

# Mount
mkdir -p /mnt/microsd
mount $MICROSD /mnt/microsd

# Backup
cp /mnt/microsd/boot/grub/grub.cfg /mnt/microsd/boot/grub/grub.cfg.bak

# Update
sed -i "s/$OLD_VERSION/$NEW_VERSION/g; s/$OLD_KERNEL/$NEW_KERNEL/g" /mnt/microsd/boot/grub/grub.cfg

# Verify
echo "Verifying changes..."
grep "$NEW_VERSION" /mnt/microsd/boot/grub/grub.cfg | head -3

# Cleanup
sync
umount /mnt/microsd

echo "Done! MicroSD GRUB updated. Safe to reboot."
```

Usage:
```bash
chmod +x fix-microsd-grub.sh
./fix-microsd-grub.sh 24.04.2 25.10.1 6.6.32 6.12.33
```

## Additional Resources

- [TrueNAS Documentation](https://www.truenas.com/docs/)
- [HP MicroServer Gen8 Specifications](https://support.hpe.com/hpesc/public/docDisplay?docId=c03793258)
- [ZFS Feature Flags](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Feature%20Flags.html)

## Author Notes

This procedure was tested on:
- HP MicroServer Gen8
- TrueNAS SCALE Dragonfish 24.04.2 → Goldeye 25.10.1
- 4x 18TB WD drives in RAIDZ1
- Custom boot configuration with MicroSD GRUB MBR

Your mileage may vary with different hardware configurations.
