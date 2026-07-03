# linux-scripts

A personal collection of Linux shell utilities and helpers for workstation maintenance, hardware inspection, networking diagnostics, and secure operations.

## Overview

This repository is designed as a home-grown toolbox for daily Linux tasks. It includes scripts for:

- cron job editing and management
- USB/removable disk identification and safe wiping
- file verification with GPG and checksums
- Firefox stale-lock cleanup
- virtual disk image compaction for GNOME Boxes/QEMU
- Windows 11 VM preparation for GNOME Boxes
- GNOME keyboard shortcut export/import
- GPG secret key summaries
- IKE VPN transform scanning
- Blu-ray playback helper installation
- PowerShell installation on RHEL-compatible Linux
- MAC vendor lookup and device information
- RPM key inspection
- shell logging support for personal scripts
- URL redirect inspection
- public IP diagnostics
- WHOIS/RDAP registration lookup
- firmware OEM Windows key extraction

## Install

The repository includes two helper installers:

- `install-links.sh`: create, remove, list, and clean symlinks from this repo into `~/bin`
- `INSTALL`: generic install script for creating or removing symlinks into a destination directory

To install all executable scripts into `~/bin`:

```bash
./install-links.sh create
```

Or, using the generic installer:

```bash
./INSTALL --create ~/bin
```

To remove the installed links:

```bash
./install-links.sh remove
```

Or:

```bash
./INSTALL --remove ~/bin
```

## Example commands

```bash
./cron-edit.sh list
./erase-usb.sh --select-latest-usb /dev/sdX
./file-verify.sh downloaded.iso
./firefox-clear-stale-locks.sh
./gb-disk-compact.sh /path/to/disk.qcow2
./gb-prepare-win11.sh --domain "Windows 11" 
./python3 gnome-keybindings.py export keybindings.json
./gpg-secret-key-summary.sh
./ike-transform-scan.sh 192.0.2.1
./install-bluray-playback.sh --dry-run
./install-powershell-rhel.sh
./latest-usb-disk.sh --plain
./list-group-members.sh wheel
./list-usb-sticks.sh
./python3 mac-vendor.py 00:11:22:33:44:55
./rpm-trusted-keys.sh --rpmkeys
./urlxray.sh https://tinyurl.com/example
./whatismyip.sh --json
./whois-rdap.sh example.com
./show-windows-oem-key.sh --show
```

## Included scripts

- `cron-edit.sh` — manage the current user's crontab entries safely.
- `erase-usb.sh` — safely erase whole USB/removable block devices with zero/random/discard/wipefs options.
- `file-verify.sh` — verify release artifacts using detached GPG signatures and checksum files.
- `firefox-clear-stale-locks.sh` — remove stale Firefox profile lock files.
- `gb-disk-compact.sh` — compact qcow2 disk images for KVM/libvirt/GNOME Boxes.
- `gb-prepare-win11.sh` — add TPM and UEFI/Secure Boot support to GNOME Boxes Windows 11 VMs.
- `gnome-keybindings.py` — export and import GNOME keyboard shortcuts.
- `gpg-secret-key-summary.sh` — print a safe summary of local GPG secret keys.
- `ike-transform-scan.sh` — scan accepted IKEv1 Phase 1 transform proposals on a target.
- `install-bluray-playback.sh` — configure VLC and AACS support for Blu-ray playback on Fedora/Ubuntu.
- `install-links.sh` — manage symlinks for executable files from this repo.
- `install-powershell-rhel.sh` — install Microsoft PowerShell on RHEL-compatible Linux systems.
- `latest-usb-disk.sh` — identify the most recently attached USB/removable whole-disk device.
- `list-group-members.sh` — list members of a Unix/Linux group.
- `list-usb-sticks.sh` — list attached USB/removable disks and active dd jobs.
- `mac-vendor.py` — lookup IEEE MAC vendor assignment information.
- `rpm-trusted-keys.sh` — list public keys imported into the RPM database.
- `shell-logging.sh` — reusable Bash logging helper library for scripts.
- `show-windows-oem-key.sh` — read embedded Windows OEM product keys from ACPI MSDM.
- `urlxray.sh` — inspect URL redirect chains and effective destinations.
- `whatismyip.sh` — compare public IPv4/IPv6 addresses from multiple providers.
- `whois-rdap.sh` — gather WHOIS and RDAP registration data for domains and IP addresses.

## Requirements

Each script may have its own dependencies. Common requirements include:

- `bash` / `sh`
- `python3`
- GNU utilities: `awk`, `grep`, `sed`, `sort`, `uniq`, `curl`, `wget`, `gpg`, `whois`, `curl`, `jq`, `lsblk`, `udevadm`, `rpm`, `dnf`, `qemu-img`

Refer to each script's header comments for exact requirements and supported platforms.

## Notes

- Many scripts are intended for Fedora/RHEL-based systems, but most are generally portable to Linux distributions with the required tools installed.
- Use caution with destructive utilities like `erase-usb.sh` and `gb-disk-compact.sh`.
- The repository is authored and maintained by Torsten Juul-Jensen.
