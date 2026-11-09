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
python3 gnome-keybindings.py --export keybindings.json
bash gnome-keybindings.sh --export keybindings.json
./gpg-secret-key-summary.sh
./ike-transform-scan.sh 192.0.2.1
./install-bluray-playback.sh --dry-run
./install-powershell-rhel.sh
./latest-usb-disk.sh --plain
./list-group-members.sh wheel
./list-usb-sticks.sh
./python3 mac-vendor.py 00:11:22:33:44:55
bash mac-vendor.sh --json 00:11:22:33:44:55
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
- `gnome-keybindings.sh` — Bash/jq companion for JSON import/export of GNOME keyboard shortcuts, compatible with Python exports.
- `gpg-secret-key-summary.sh` — print a safe summary of local GPG secret keys.
- `ike-transform-scan.sh` — scan accepted IKEv1 Phase 1 transform proposals on a target.
- `install-bluray-playback.sh` — configure VLC and AACS support for Blu-ray playback on Fedora/Ubuntu.
- `install-links.sh` — manage symlinks for executable files from this repo.
- `install-powershell-rhel.sh` — install Microsoft PowerShell on RHEL-compatible Linux systems.
- `latest-usb-disk.sh` — identify the most recently attached USB/removable whole-disk device.
- `list-group-members.sh` — list members of a Unix/Linux group.
- `list-usb-sticks.sh` — list attached USB/removable disks and active dd jobs.
- `mac-vendor.py` — lookup IEEE MAC vendor assignment information.
- `mac-vendor.sh` — Bash equivalent of `mac-vendor.py`, using the same IEEE cache without a Python runtime dependency.
- `rpm-trusted-keys.sh` — list public keys imported into the RPM database.
- `bash-logger-lib.sh` — reusable Bash logging helper library; source it with `source /path/to/bash-logger-lib.sh` to use the `log_*` functions.
- `show-windows-oem-key.sh` — read embedded Windows OEM product keys from ACPI MSDM.
- `urlxray.sh` — inspect URL redirect chains and effective destinations.
- `whatismyip.sh` — compare public IPv4/IPv6 addresses from multiple providers.
- `whois-rdap.sh` — gather WHOIS and RDAP registration data for domains and IP addresses.

For IPs, `whois-rdap.sh` follows explicit WHOIS registry pointers, including
KRNIC, JPNIC (using English output), and TWNIC. Its text output stays concise
and takes network classification and RPSL organization details from the most
specific matching record. Use `--raw` or `--save` for complete responses.

On Fedora, install its CLI dependencies with
`sudo dnf install whois curl jq ipcalc`.

## MAC vendor lookup in Bash

`mac-vendor.sh` requires Bash 4+, `awk`, standard Unix utilities (including
`mktemp` and `stat`), and `curl` for cache downloads. Python and `jq` are not
required to run it. It uses the same options and TSV cache as `mac-vendor.py`:

```bash
bash mac-vendor.sh --update
bash mac-vendor.sh --offline --show-address 00:1A:2B:33:44:55
bash mac-vendor.sh --quiet 00-1A-2B
printf '%s\n' 00:1A:2B:33:44:55 3C:52:82:AA:BB:CC | bash mac-vendor.sh --json
```

The default cache is `$XDG_CACHE_HOME/mac-vendor`, or
`$HOME/.cache/mac-vendor`, with a seven-day freshness threshold. Lookups stay
local; queried addresses are never sent to IEEE. Both implementations match
the longest available MA-L, MA-M, MA-S or IAB prefix and keep the first exact
duplicate in an existing cache. Refreshes replace the cache only after all
four registries have downloaded and parsed successfully.

In both scripts, combining `--update` with `--offline` is a CLI error (exit 2),
detected before any cache access or download.
An update without addresses exits successfully on a terminal; with piped
input it proceeds to lookups, and empty input exits 2. Unknown vendors exit 0,
invalid addresses and handled runtime errors exit 1, CLI errors exit 2, and
Ctrl+C exits 130. Combining `--quiet` with `--json` returns a JSON array with
only the `organization` field for each query, such as
`[{"organization": "Example Vendor"}]`. Unknown vendors use
`{"organization": null}`. Without `--quiet`, JSON includes all lookup fields.

Practical port differences: help layout, curl's transport error wording and
connect/low-speed timeouts instead of urllib's socket timeout, and concise
errors instead of Python tracebacks for filesystem failures or invalid network
timeouts. Metadata and the HTTP User-Agent identify `mac-vendor.sh`; metadata
timestamps have second precision. Normal UTF-8 registry text is preserved;
Python-specific behavior for malformed UTF-8, exotic Unicode numeric arguments
and nonprintable Unicode error representations is not reproduced.

Run the deterministic comparison tests on Linux with Python 3 installed:

```bash
python3 tests/test_mac_vendor.py
```

The tests compare the Bash port with the actual Python source, using local
registry fixtures, simulated download failures and pseudo-terminal input.
They do not access the public network. For a Windows-hosted checkout, run
them from a disposable copy inside the WSL Linux filesystem.

## GNOME keyboard shortcuts in Bash

`gnome-keybindings.sh` requires Bash 4+, jq 1.6+, `gsettings`, and standard
Unix utilities. It does not require Python. It uses the Python script's JSON
format and preserves GSettings values as strings, including quoted custom
commands. JSON exports can be imported by either implementation.

```bash
bash gnome-keybindings.sh --export keybindings.json
bash gnome-keybindings.sh --import keybindings.json --dry-run
bash gnome-keybindings.sh --import keybindings.json --preserve-custom-paths
bash gnome-keybindings.sh --export --normalize-disabled
cat keybindings.json | bash gnome-keybindings.sh --import -
```

The CLI follows `gnome-keybindings.py`, with JSON as the only format:
`--format json` is accepted, while `--format tsv` and TSV imports are rejected.
The Python script retains its legacy TSV support. Without `--export` or
`--import`, an existing filename implies import; otherwise the action is
export. The default filename is `-`, meaning stdin for import and stdout for
export. Piped input alone does not imply import; specify `--import`.

Run imports as the intended desktop user in their GNOME session. `--dry-run`
prints the `gsettings set` commands without applying them; on export it behaves
like the Python option and still produces an export. `--normalize-disabled`
turns `['disabled']` and `['']` values into `[]` during export.

Custom paths are renumbered by default; `--preserve-custom-paths` reuses paths
from the JSON file. **`--no-replace-custom` does not merge shortcuts:** matching
Python, it skips the initial clearing step, but the final path list still
contains only the imported custom shortcuts. Imports with no custom items
leave the custom path list alone. Failed writes are reported and subsequent
settings are still attempted; there is no automatic rollback.

Exit statuses are 0 for success, 1 for runtime/import failures, 2 for CLI
errors, and 130 for interruption. The Bash version validates all known import
items before writing and rejects malformed fields or NUL characters. Its
metadata identifies `gnome-keybindings.sh` and uses second-precision UTC
timestamps; help layout and parser diagnostics differ from Python. GSettings
string arrays are parsed as data, without evaluating shell or Python code.

Run the comparison tests on Linux with Python 3 and jq installed:

```bash
python3 tests/test_gnome_keybindings.py
```

Tests put a mock `gsettings` in an isolated command path, compare exports and
exact import arguments with the Python original, and never access desktop
shortcuts. For a Windows-hosted checkout, run from a disposable copy inside
the WSL Linux filesystem.

## Public IP lookup dependencies and results

`whatismyip.sh` uses the available public-IP providers. If `dig` is missing,
it skips OpenDNS and Google DNS lookups and uses ipify HTTPS through `curl`.
If `curl` is missing, DNS lookups still work with `dig`. The `ip` command is
optional: without it, local-route information is skipped.

At least one public-IP lookup method must be available and enabled. Missing
both `dig` and `curl`, or missing `dig` while using `--no-https`, `--no-ipify`,
or `--no-curl-fallback`, produces a clear error and exits 1. JSON output still
requires `jq`. The optional `timeout` command adds a command deadline;
`dig` and `curl` also receive their own timeout settings.

Normal text output identifies skipped providers and reports dependency
warnings on stderr. Diagnostic JSON (`--json --debug`) includes provider
statuses and warnings. Quiet text and quiet JSON remain limited to resolved
public addresses. Local-route addresses never count as public-IP results.

Result and diagnostic JSON include `providerCount` (successful public
providers, before deduplication) and `status` for each enabled address family:

| Successful public providers | Status | JSON `consistent` |
| --- | --- | --- |
| None | `unavailable` | `null` |
| One | `single_provider` ("single provider" in text) | `null` |
| Two or more, all agreeing | `consistent` | `true` |
| Two or more, disagreeing | `provider_mismatch` | `false` |

Consumers of the JSON output should allow `consistent` to be `null` when
there are too few results to compare. Individual lookup failures report
`unavailable` without aborting the remaining lookups; if all lookups fail,
quiet text is empty and quiet JSON is `{}`.

Run the isolated, network-free dependency and output tests on Linux:

```bash
python3 tests/test_whatismyip.py
```

For a Windows-hosted checkout, use a disposable copy inside the WSL Linux
filesystem, as with the MAC vendor tests.

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
