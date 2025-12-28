# installing Debian packages on TrueNAS SCALE 25.10 (Goldeye)

this guide explains how to install Debian packages using `apt` on TrueNAS SCALE 25.10.x (Goldeye) and other recent versions (25.04 Fangtooth, 24.10 Electric Eel).

## Background

TrueNAS SCALE is designed as an appliance and intentionally blocks the use of `apt` to protect the system from modifications that could break functionality during updates. When you try to run `apt install`, you'll encounter an error like:

```
sudo: process 217740 unexpected status 0x57f
zsh: killed     apt install screen
```

this happens because TrueNAS uses rootfs protection and system extensions to lock down the base system.

## ⚠️ Warnings

- **unsupported configuration**: enabling developer mode means iXsystems will not provide support for issues related to your modifications.
- **updates may reset changes**: TrueNAS system updates may reset developer mode, requiring you to repeat the initial setup.
- **installed packages may be removed**: system updates can wipe out packages you've installed.
- **potential for breakage**: installing or upgrading system packages could conflict with TrueNAS components. never run `apt upgrade` on the entire system.

## initial setup (one-time)

these steps only need to be performed once (or after a TrueNAS system update resets the configuration).

### step 1: unmerge system extensions

```bash
sudo systemd-sysext unmerge
```

### step 2: enable developer mode

```bash
sudo install-dev-tools
```

### step 3: reboot

```bash
sudo reboot
```

the reboot is required for the changes to take effect and for the `/boot` path to become writable.

## installing packages

after the initial setup is complete, use this workflow whenever you need to install packages.

### step 1: unmerge system extensions

```bash
sudo systemd-sysext unmerge
```

### Step 2: Install Your Packages

```bash
apt update
apt install <package-name>
```

for example:

```bash
apt install screen htop
```

> **note**: you may see warnings about `initramfs-tools` and read-only file system errors at the end of the installation. These typically don't affect the package installation for most packages.

### step 3: re-merge system extensions (optional)

```bash
sudo systemd-sysext merge
```

this step is optional if you plan to install more packages. however, keep in mind:

- some TrueNAS features (like NVIDIA GPU support) depend on system extensions being merged.
- a system reboot will automatically re-merge the extensions.

## quick reference

| Task | Command |
|------|---------|
| unmerge extensions | `sudo systemd-sysext unmerge` |
| enable developer mode | `sudo install-dev-tools` |
| update package lists | `apt update` |
| install a package | `apt install <package>` |
| re-merge extensions | `sudo systemd-sysext merge` |

## tested versions

- TrueNAS SCALE 25.10.1 (Goldeye)
- TrueNAS SCALE 25.04.x (Fangtooth)
- TrueNAS SCALE 24.10.x (Electric Eel)

## references

- [TrueNAS forums: install-dev-tools discussion](https://forums.truenas.com/t/is-install-dev-tools-broken-in-24-10-2/28673)
- [TrueNAS documentation: developer mode](https://www.truenas.com/docs/)

## license

This documentation is provided as-is for informational purposes. use at your own risk. 
