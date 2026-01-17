# TrueNAS SCALE upgrade guide for HP MicroServer Gen8

## overview

this guide documents the process of upgrading TrueNAS SCALE on an HP MicroServer Gen8 with a custom boot configuration. the server uses a MicroSD card with GRUB in the MBR to chainload to an SSD on the ODD SATA port, which the BIOS cannot directly boot from.

## additional documentation

| document | description |
| --- | --- |
| [DEBIAN_PACKAGES.md](DEBIAN_PACKAGES.md) | how to install Debian packages using `apt` on TrueNAS SCALE 25.10.1 and later versions |
| [swap configuration](swap-configuration/) | configure 8GB swap on TrueNAS SCALE 25.10+ using ZFS zvol for optimal performance and OOM protection |

## hardware configuration

* **server**: HP MicroServer Gen8
* **hostname**: bender
* **boot device**: MicroSD card (~60GB) with GRUB MBR
* **system drive**: SSD on ODD SATA port (not BIOS-bootable)
* **data pool**: 4x 18TB WD drives in RAIDZ1 named "BIG"

## boot chain

1. BIOS boots from MicroSD MBR (only bootable device BIOS recognizes)
2. MicroSD GRUB chainloads to SSD on ODD SATA port
3. SSD contains actual TrueNAS installation

## the problem

when TrueNAS updates:

* it creates a new boot environment (e.g., `ROOT/25.10.1`)
* it updates GRUB on the SSD
* it does NOT update the MicroSD GRUB config
* MicroSD GRUB still references old boot environment → boot fails

## pre-upgrade steps

### 1. identify your MicroSD device

```
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL,TRAN
```

look for the MicroSD card - in this case it was `sde` (59.5GB, "Internal SD-CARD").

### 2. backup current MicroSD GRUB config

```
mkdir -p /mnt/microsd
mount /dev/sde1 /mnt/microsd
cp /mnt/microsd/boot/grub/grub.cfg ~/grub-microsd-backup-$(date +%Y%m%d).cfg
umount /mnt/microsd
```

### 3. download TrueNAS configuration

via web UI:

* **System** → **General** → **Manage Configuration** → **Download File**

### 4. save pool metadata (optional but recommended)

```
zpool status BIG > ~/pool-status-backup.txt
zfs list -r BIG > ~/datasets-backup.txt
zpool get all BIG > ~/pool-properties-backup.txt

# Copy these to your local machine
scp root@bender:~/*backup.txt .
```

### 5. verify iLO/console access

ensure you have working HP iLO access as you'll need it after reboot.

## upgrade process

### step 1: apply the update

via web UI:

1. go to **System** → **Update**
2. click **Download Updates** (if not already downloaded)
3. click **Apply Pending Update**
4. system will install and automatically reboot
5. **boot will fail** (this is expected)

### step 2: manual boot via iLO console

when GRUB menu appears (showing old version "TrueNAS Scale GNU/Linux 24.04.2"):

1. **press `e`** to edit the boot entry
2. **locate and modify** these lines:

find:

```
linux /ROOT/24.04.2@/boot/vmlinuz-6.6.32-production+truenas root=ZFS=boot-pool/ROOT/24.04.2 ...
```

change to:

```
linux /ROOT/25.10.1@/boot/vmlinuz-6.12.33-production+truenas root=ZFS=boot-pool/ROOT/25.10.1 ...
```

find:

```
initrd /ROOT/24.04.2@/boot/initrd.img-6.6.32-production+truenas
```

change to:

```
initrd /ROOT/25.10.1@/boot/initrd.img-6.12.33-production+truenas
```

3. **press `Ctrl+X`** or `F10` to boot

### step 3: permanently fix MicroSD GRUB

once the system boots successfully:

**IMPORTANT**: device names may have changed after reboot. find your MicroSD:

```
# Check current device mapping
lsblk -o NAME,SIZE,TYPE,FSTYPE

# Find the ext4 partition (~128M)
blkid | grep ext4 | grep -v boot-pool
```

in our case, the MicroSD shifted from `sde1` to `sdf1` after reboot.

mount and fix the configuration:

```
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

### step 4: test automatic boot

```
reboot
```

system should now boot automatically without manual intervention.

### step 5: verify upgrade

after successful boot:

```
# Check version
cat /etc/version  # Should show: TrueNAS-SCALE-25.10.1

# Check kernel
uname -r  # Should show: 6.12.33-production+truenas

# Verify pool health
zpool status BIG

# Check boot environments
zfs list -r boot-pool/ROOT
```

## version-specific details

### Dragonfish 24.04.2 → Goldeye 25.10.1

* **old kernel**: 6.6.32-production+truenas
* **new kernel**: 6.12.33-production+truenas
* **old boot environment**: ROOT/24.04.2
* **new boot environment**: ROOT/25.10.1

## troubleshooting

### boot fails after update

**symptom**: system doesn't boot after update
**solution**: use iLO console to manually edit GRUB (step 2 above)

### can't find MicroSD after reboot

**symptom**: device names changed, can't find MicroSD
**solution**:

```
lsblk -o NAME,SIZE,FSTYPE
blkid | grep ext4
```

look for the small (~128M) ext4 partition.

### wrong kernel version

**symptom**: kernel version in GRUB doesn't match
**solution**: check actual kernel version on SSD:

```
ls /boot/ROOT/25.10.1@/boot/vmlinuz-*
```

use the exact filename shown.

### pool won't import

**symptom**: BIG pool doesn't show up after upgrade
**solution**:

```
# Manually import pool
zpool import BIG

# Or if that fails, list importable pools
zpool import
```

## important notes

* **no need to run `update-grub`** - you're only editing the config file, not reinstalling GRUB
* **device names (`/dev/sdX`) may change** between reboots, but ZFS uses UUIDs so pools remain accessible
* **your data pool is separate** from the boot device and won't be touched during upgrade
* **keep the old boot environment** - don't delete ROOT/24.04.2 until you've verified 25.10.1 is stable

## future upgrades

for future TrueNAS upgrades, repeat this process:

1. apply update via web UI
2. boot fails (expected)
3. manual boot via iLO console with new version numbers
4. fix MicroSD GRUB with new paths
5. reboot to verify

## automation script

for future upgrades, you can create a script to automate the MicroSD GRUB fix. save this as `fix-microsd-grub.sh`:

```
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

usage:

```
chmod +x fix-microsd-grub.sh
./fix-microsd-grub.sh 24.04.2 25.10.1 6.6.32 6.12.33
```

## additional resources

* [TrueNAS Documentation](https://www.truenas.com/docs/)
* [HP MicroServer Gen8 Specifications](https://support.hpe.com/hpesc/public/docDisplay?docId=c03793258)
* [ZFS Feature Flags](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Feature%20Flags.html)

## author notes

this procedure was tested on:

* HP MicroServer Gen8
* TrueNAS SCALE Dragonfish 24.04.2 → Goldeye 25.10.1
* 4x 18TB WD drives in RAIDZ1
* custom boot configuration with MicroSD GRUB MBR

your mileage may vary with different hardware configurations.
