#!/usr/bin/env bash
#
# gp-prepare-win11.sh
#
# Purpose:
#   Prepare a GNOME Boxes/libvirt user-session VM for Windows 11 by adding
#   TPM 2.0 emulation and Secure Boot capable OVMF firmware to its libvirt XML.
#
# Background:
#   Windows 11 requires TPM 2.0 and UEFI/Secure Boot capability. GNOME Boxes is
#   intentionally simple and may not expose all libvirt hardware options needed
#   for that workflow. This script patches the VM after Boxes creates it.
#
# Scope:
#   Fedora/RPM GNOME Boxes using qemu:///session. Run as the normal desktop user,
#   not as root. This script does not support the GNOME Boxes Flatpak build.
#
# Safety:
#   The target VM must be shut off. A backup of the original domain XML is saved
#   before redefining the VM. The script sets the human-readable <title>, but it
#   intentionally does not rename the libvirt domain or disk image file.
#
# Fedora packages:
#   edk2-ovmf
#   swtpm-tools
#   gnome-boxes
#   libvirt-client
#
# Author:
#   Torsten Juul-Jensen
#
# Version:
#   1.0.1
#
# Date:
#   2026-07-02

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.0.1"

LIBVIRT_URI="qemu:///session"
DRY_RUN=0
VERBOSE=0
SKIP_INSTALL=0
DOMAIN=""
TITLE=""
LOADER_PATH=""
WAIT_TIMEOUT=1800

TMP_FILES=()

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_GREEN=$'\033[32m'
else
  C_RESET=""
  C_RED=""
  C_YELLOW=""
  C_BLUE=""
  C_GREEN=""
fi

log() {
  printf '%s\n' "${C_BLUE}INFO:${C_RESET} $*"
}

warn() {
  printf '%s\n' "${C_YELLOW}WARN:${C_RESET} $*" >&2
}

err() {
  printf '%s\n' "${C_RED}ERROR:${C_RESET} $*" >&2
}

success() {
  printf '%s\n' "${C_GREEN}OK:${C_RESET} $*"
}

verbose() {
  [[ "$VERBOSE" -eq 1 ]] && log "$*"
}

cleanup() {
  if [[ "${#TMP_FILES[@]}" -gt 0 ]]; then
    rm -f -- "${TMP_FILES[@]}"
  fi
}

trap cleanup EXIT

usage() {
  cat <<USAGE
${SCRIPT_NAME} ${SCRIPT_VERSION}

Prepare a GNOME Boxes/libvirt VM for Windows 11 by adding TPM 2.0 and OVMF
Secure Boot firmware to the user's libvirt session XML.

Usage:
  ${SCRIPT_NAME} [options]

Guided mode:
  ${SCRIPT_NAME}

Existing VM mode:
  ${SCRIPT_NAME} --domain NAME --title "Windows 11"

Options:
  --domain NAME
      Patch an existing libvirt domain instead of waiting for a newly created
      GNOME Boxes VM.

  --title TITLE
      Human-readable VM title. Prompted if omitted.

  --connection URI
      Libvirt connection URI.
      Default: qemu:///session

  --loader PATH
      OVMF Secure Boot loader path.
      Auto-detected by default.

  --skip-install
      Do not install Fedora packages automatically.

  --wait-timeout SEC
      Seconds to wait for a new VM in guided mode.
      Default: 1800

  --dry-run
      Show intended changes and write patched XML preview only.

  --verbose
      Print package-skip and detection details.

  -h, --help
      Show this help.

  --version
      Show version information.

Guided workflow:
  1. Run this script.
  2. In GNOME Boxes, create a VM from the Windows 11 ISO.
  3. Do not use Express Install.
  4. When Windows Setup reaches the language screen, close the installer window.
  5. Make sure the VM is shut off, then return to this terminal.

Notes:
  This script is intended for the GNOME Boxes RPM/package version using
  qemu:///session. It is not intended for the Flatpak version of GNOME Boxes.

USAGE
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

confirm() {
  local response

  read -r -p "$1 [y/N] " response
  response="${response,,}"

  [[ "$response" =~ ^(y|yes)$ ]]
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        DOMAIN="${2:-}"
        shift 2
        ;;
      --title)
        TITLE="${2:-}"
        shift 2
        ;;
      --connection)
        LIBVIRT_URI="${2:-}"
        shift 2
        ;;
      --loader)
        LOADER_PATH="${2:-}"
        shift 2
        ;;
      --skip-install)
        SKIP_INSTALL=1
        shift
        ;;
      --wait-timeout)
        WAIT_TIMEOUT="${2:-}"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        VERBOSE=1
        shift
        ;;
      --verbose)
        VERBOSE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --version)
        printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        exit 0
        ;;
      *)
        err "Unknown argument: $1"
        usage >&2
        exit 2
        ;;
    esac
  done

  if [[ ! "$WAIT_TIMEOUT" =~ ^[0-9]+$ ]]; then
    err "--wait-timeout must be an integer."
    exit 2
  fi

  if [[ -z "$DOMAIN" && "$DRY_RUN" -eq 1 ]]; then
    warn "--dry-run without --domain still requires guided VM detection."
    warn "For a pure XML patch preview, use --dry-run --domain NAME."
  fi
}

require_normal_user() {
  if [[ "$EUID" -eq 0 ]]; then
    err "Run as your normal desktop user, not root."
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

install_packages() {
  [[ "$SKIP_INSTALL" -eq 1 ]] && return 0

  if ! command_exists rpm || ! command_exists dnf; then
    warn "rpm/dnf not found; skipping automatic package install."
    return 0
  fi

  local packages=(edk2-ovmf swtpm-tools)
  local missing=()
  local pkg

  for pkg in "${packages[@]}"; do
    if rpm -q --quiet "$pkg"; then
      verbose "Package already installed: $pkg"
    else
      missing+=("$pkg")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    log "Installing missing packages: ${missing[*]}"
    run sudo dnf install -y "${missing[@]}"
  fi
}

check_requirements() {
  local commands=(virsh python3 swtpm_setup)
  local cmd

  for cmd in "${commands[@]}"; do
    if ! command_exists "$cmd"; then
      err "Required command not found: $cmd"

      if [[ "$cmd" == "swtpm_setup" ]]; then
        err "On Fedora, install the swtpm-tools package."
      fi

      exit 1
    fi
  done

  if [[ -z "$DOMAIN" ]] && ! command_exists gnome-boxes; then
    err "gnome-boxes command not found. Install the RPM/package version of GNOME Boxes."
    exit 1
  fi

  if ! virsh -c "$LIBVIRT_URI" uri >/dev/null 2>&1; then
    err "Cannot connect to libvirt URI: $LIBVIRT_URI"
    exit 1
  fi

  if [[ ! -e /dev/kvm ]]; then
    warn "/dev/kvm not found. Hardware virtualization may be disabled in BIOS/UEFI."
  elif [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    warn "/dev/kvm exists, but this user may not have access to it."
  fi
}

find_loader() {
  if [[ -n "$LOADER_PATH" ]]; then
    if [[ ! -r "$LOADER_PATH" ]]; then
      err "Loader path is not readable: $LOADER_PATH"
      exit 1
    fi

    return 0
  fi

  local candidates=(
    /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd
    /usr/share/OVMF/OVMF_CODE.secboot.fd
  )

  local path

  for path in "${candidates[@]}"; do
    if [[ -r "$path" ]]; then
      LOADER_PATH="$path"
      verbose "Using OVMF loader: $LOADER_PATH"
      return 0
    fi
  done

  err "Could not find OVMF_CODE.secboot.fd. Install edk2-ovmf or use --loader PATH."
  exit 1
}

find_nvram_template() {
  local dir

  dir="$(dirname -- "$LOADER_PATH")"

  if [[ -r "${dir}/OVMF_VARS.secboot.fd" ]]; then
    printf '%s\n' "${dir}/OVMF_VARS.secboot.fd"
  else
    printf '\n'
  fi
}

list_domains() {
  virsh -c "$LIBVIRT_URI" list --all --name | sed '/^$/d' | sort
}

start_boxes() {
  if pidof -q gnome-boxes; then
    verbose "GNOME Boxes already running."
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: gnome-boxes &\n'
  else
    nohup gnome-boxes >/dev/null 2>&1 &
  fi
}

wait_for_new_domain() {
  local before
  local after
  local new
  local start
  local now

  before="$(mktemp)"
  after="$(mktemp)"
  new="$(mktemp)"
  TMP_FILES+=("$before" "$after" "$new")

  list_domains > "$before"

  cat <<'INSTRUCTIONS'

Create the VM in GNOME Boxes now. Stop at the first Windows Setup language
screen, close the installer window, and make sure the VM is shut off.

INSTRUCTIONS

  start_boxes
  start="$(date +%s)"

  while true; do
    list_domains > "$after"
    comm -13 "$before" "$after" > "$new" || true

    if [[ -s "$new" ]]; then
      DOMAIN="$(head -n 1 "$new")"
      log "Detected new VM: $DOMAIN"
      return 0
    fi

    now="$(date +%s)"

    if (( now - start >= WAIT_TIMEOUT )); then
      err "Timed out waiting for a new VM."
      exit 1
    fi

    sleep 2
  done
}

ensure_domain_ready() {
  local state

  if ! virsh -c "$LIBVIRT_URI" dominfo "$DOMAIN" >/dev/null 2>&1; then
    err "Domain not found: $DOMAIN"
    exit 1
  fi

  state="$(virsh -c "$LIBVIRT_URI" domstate "$DOMAIN" | tr '[:upper:]' '[:lower:]')"

  if [[ "$state" != "shut off" ]]; then
    warn "Domain '$DOMAIN' is currently: $state"

    if confirm "Force power off the VM with virsh destroy?"; then
      run virsh -c "$LIBVIRT_URI" destroy "$DOMAIN"
    else
      err "The VM must be shut off before patching."
      exit 1
    fi
  fi
}

prompt_title() {
  [[ -n "$TITLE" ]] && return 0

  read -r -p "Enter VM title: " TITLE

  if [[ -z "${TITLE// }" ]]; then
    err "VM title cannot be empty."
    exit 1
  fi
}

backup_path() {
  local dir

  dir="$HOME/.local/share/gp-prepare-win11/backups/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"

  printf '%s/%s.original.xml\n' "$dir" "$DOMAIN"
}

patch_xml() {
  local source_xml="$1"
  local patched_xml="$2"
  local nvram_template="$3"
  local nvram_path="$4"

  python3 - "$source_xml" "$patched_xml" "$TITLE" "$LOADER_PATH" "$nvram_template" "$nvram_path" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

source_xml, patched_xml, title, loader_path, nvram_template, nvram_path = sys.argv[1:7]

ET.register_namespace("boxes", "https://wiki.gnome.org/Apps/Boxes")
ET.register_namespace("osinfo", "http://libosinfo.org/xmlns/libvirt/domain/1.0")


def local_name(tag):
    return tag.rsplit("}", 1)[-1]


def indent(elem, level=0):
    space = "\n" + level * "  "

    if len(elem):
        if not elem.text or not elem.text.strip():
            elem.text = space + "  "

        for child in elem:
            indent(child, level + 1)

        if not elem[-1].tail or not elem[-1].tail.strip():
            elem[-1].tail = space

    if level and (not elem.tail or not elem.tail.strip()):
        elem.tail = space


parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
tree = ET.parse(source_xml, parser=parser)
root = tree.getroot()

title_el = root.find("title")

if title_el is None:
    title_el = ET.Element("title")
    name_el = root.find("name")
    insert_at = list(root).index(name_el) + 1 if name_el is not None else 0
    root.insert(insert_at, title_el)

title_el.text = title

os_el = root.find("os")

if os_el is None:
    raise SystemExit("domain XML has no <os> element")

loader_el = os_el.find("loader")

if loader_el is None:
    loader_el = ET.Element(
        "loader",
        {
            "readonly": "yes",
            "secure": "yes",
            "type": "pflash",
        },
    )
    loader_el.text = loader_path
    type_el = os_el.find("type")
    insert_at = list(os_el).index(type_el) + 1 if type_el is not None else 0
    os_el.insert(insert_at, loader_el)
else:
    loader_el.set("readonly", loader_el.get("readonly", "yes"))
    loader_el.set("secure", loader_el.get("secure", "yes"))
    loader_el.set("type", loader_el.get("type", "pflash"))

    if not (loader_el.text and loader_el.text.strip()):
        loader_el.text = loader_path

if nvram_template and os_el.find("nvram") is None:
    nvram_el = ET.Element("nvram", {"template": nvram_template})
    nvram_el.text = nvram_path
    os_el.insert(list(os_el).index(loader_el) + 1, nvram_el)

devices_el = root.find("devices")

if devices_el is None:
    raise SystemExit("domain XML has no <devices> element")

if devices_el.find("tpm") is None:
    tpm_el = ET.Element("tpm", {"model": "tpm-crb"})
    ET.SubElement(tpm_el, "backend", {"type": "emulator", "version": "2.0"})
    devices_el.insert(0, tpm_el)

iso_path = None

for elem in root.iter():
    if local_name(elem.tag) == "media" and elem.text and elem.text.strip():
        candidate = elem.text.strip()

        if os.path.exists(candidate):
            iso_path = candidate
            break

if iso_path:
    for disk in devices_el.findall("disk"):
        if disk.get("device") == "cdrom" and disk.find("source") is None:
            disk.set("type", "file")
            source_el = ET.Element("source", {"file": iso_path})
            driver_el = disk.find("driver")
            insert_at = list(disk).index(driver_el) + 1 if driver_el is not None else 0
            disk.insert(insert_at, source_el)
            break

indent(root)
tree.write(patched_xml, encoding="unicode", xml_declaration=True)
PY
}

patch_domain() {
  local original_xml
  local patched_xml
  local nvram_template
  local nvram_dir
  local nvram_path

  ensure_domain_ready
  prompt_title

  original_xml="$(backup_path)"
  patched_xml="$(mktemp --suffix=.xml)"
  TMP_FILES+=("$patched_xml")

  nvram_template="$(find_nvram_template)"
  nvram_dir="$HOME/.config/libvirt/qemu/nvram"
  nvram_path="${nvram_dir}/${DOMAIN}_VARS.fd"

  log "Backing up domain XML."
  virsh -c "$LIBVIRT_URI" dumpxml --inactive "$DOMAIN" > "$original_xml"

  if [[ -n "$nvram_template" ]]; then
    run mkdir -p "$nvram_dir"
  else
    warn "No OVMF_VARS.secboot.fd template found beside loader; continuing without explicit NVRAM template."
  fi

  patch_xml "$original_xml" "$patched_xml" "$nvram_template" "$nvram_path"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry run: patched XML preview written to $patched_xml"
    log "Original XML backup written to $original_xml"
    return 0
  fi

  log "Redefining libvirt domain."
  virsh -c "$LIBVIRT_URI" define "$patched_xml" >/dev/null

  success "VM '$DOMAIN' prepared for Windows 11."
  log "Backup: $original_xml"
}

main() {
  parse_args "$@"
  require_normal_user
  install_packages
  check_requirements
  find_loader

  log "Ensuring SWTPM user config files exist."
  run swtpm_setup --create-config-files skip-if-exist

  if [[ -z "$DOMAIN" ]]; then
    wait_for_new_domain
  fi

  patch_domain

  if [[ "$DRY_RUN" -ne 1 ]]; then
    start_boxes
  fi
}

main "$@"