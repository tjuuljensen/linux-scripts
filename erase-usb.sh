#!/usr/bin/env bash
#
# erase-usb.sh
#
# Purpose:
#   Safely erase a whole USB/removable block device.
#
# Description:
#   This script validates that the target is a whole block device, verifies that
#   it appears to be USB or removable, refuses to continue if partitions are
#   mounted, shows clear device identity information, and requires explicit
#   confirmation before erasing.
#
#   The script can also auto-select the most recently initialized USB/removable
#   whole-disk device with --select-latest-usb.
#
# Supported erase methods:
#   zero            Overwrite the whole device with zeroes.
#   random          Overwrite the whole device with random data. Slow.
#   discard         Run blkdiscard on the whole device, if supported.
#   secure-discard  Run blkdiscard --secure, if supported by the device.
#   wipefs          Remove filesystem/partition signatures only. Does not erase
#                   the underlying data.
#
# Security notes:
#   - For normal reuse, "wipefs" or "zero" is usually enough.
#   - For flash media, overwrite-based erasure is not a perfect secure-erase
#     guarantee because USB flash controllers may remap physical blocks.
#   - For highly sensitive data on cheap USB flash media, physical destruction
#     or prior full-disk encryption is safer than relying on overwrite erasure.
#
# Requirements:
#   bash, lsblk, blockdev, udevadm, sync, readlink, awk, sort, head
#
# Optional:
#   dd, blkdiscard, wipefs
#
# Author:
#   Torsten Juul-Jensen
#
# Version:
#   1.1.0
#
# Date:
#   2026-07-02

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.1.0"

DEVICE=""
METHOD="zero"
YES=0
DRY_RUN=0
VERBOSE=0
ALLOW_NON_USB=0
UNMOUNT=0
BLOCK_SIZE="16M"
SELECT_LATEST_USB=0

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

ok() {
  printf '%s\n' "${C_GREEN}OK:${C_RESET} $*"
}

verbose() {
  [[ "$VERBOSE" -eq 1 ]] && log "$*"
}

usage() {
  cat <<USAGE
${SCRIPT_NAME} ${SCRIPT_VERSION}

Erase a whole USB/removable block device.

Usage:
  ${SCRIPT_NAME} [options] /dev/sdX
  ${SCRIPT_NAME} --select-latest-usb [options]

Options:
  --select-latest-usb
      Automatically select the most recently initialized USB/removable
      whole-disk device.

      This still requires interactive confirmation and cannot be combined with
      --yes.

  --method zero|random|discard|secure-discard|wipefs
      Erase method.
      Default: zero

  --yes
      Do not prompt interactively.
      Use with extreme care.
      Cannot be combined with --select-latest-usb.

  --dry-run
      Show what would be done without erasing anything.

  --unmount
      Attempt to unmount mounted child partitions before erasing.

  --allow-non-usb
      Allow erasing a device that does not appear to be USB/removable.
      Use with extreme care.
      Ignored when --select-latest-usb is used.

  --block-size SIZE
      Block size for dd-based zero/random overwrite.
      Default: 16M

  --verbose
      Print extra diagnostic information.

  -h, --help
      Show this help.

  --version
      Show version information.

Examples:
  ${SCRIPT_NAME} --dry-run /dev/sdb

  ${SCRIPT_NAME} --method zero /dev/sdb

  ${SCRIPT_NAME} --method wipefs /dev/sdb

  ${SCRIPT_NAME} --method secure-discard /dev/sdb

  ${SCRIPT_NAME} --select-latest-usb --dry-run

  ${SCRIPT_NAME} --select-latest-usb --method zero

Important:
  Use the whole disk device, for example /dev/sdb.
  Do not use a partition path such as /dev/sdb1.

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

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

die() {
  err "$*"
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --select-latest-usb)
        SELECT_LATEST_USB=1
        shift
        ;;
      --method)
        METHOD="${2:-}"
        shift 2
        ;;
      --yes)
        YES=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        VERBOSE=1
        shift
        ;;
      --unmount)
        UNMOUNT=1
        shift
        ;;
      --allow-non-usb)
        ALLOW_NON_USB=1
        shift
        ;;
      --block-size)
        BLOCK_SIZE="${2:-}"
        shift 2
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
      -*)
        err "Unknown option: $1"
        usage >&2
        exit 2
        ;;
      *)
        if [[ -n "$DEVICE" ]]; then
          die "Only one device may be specified."
        fi
        DEVICE="$1"
        shift
        ;;
    esac
  done

  case "$METHOD" in
    zero|random|discard|secure-discard|wipefs) ;;
    *)
      die "--method must be one of: zero, random, discard, secure-discard, wipefs"
      ;;
  esac

  if [[ "$SELECT_LATEST_USB" -eq 1 && -n "$DEVICE" ]]; then
    die "Use either --select-latest-usb or an explicit device path, not both."
  fi

  if [[ "$SELECT_LATEST_USB" -eq 1 && "$YES" -eq 1 ]]; then
    die "--select-latest-usb cannot be combined with --yes."
  fi

  if [[ "$SELECT_LATEST_USB" -ne 1 && -z "$DEVICE" ]]; then
    usage >&2
    exit 2
  fi
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    die "Run this script as root, for example: sudo ./${SCRIPT_NAME} ..."
  fi
}

check_commands() {
  local required=(lsblk blockdev udevadm sync readlink awk sort head)
  local cmd

  for cmd in "${required[@]}"; do
    command_exists "$cmd" || die "Required command not found: $cmd"
  done

  case "$METHOD" in
    zero|random)
      command_exists dd || die "Required command not found for method '$METHOD': dd"
      ;;
    discard|secure-discard)
      command_exists blkdiscard || die "Required command not found for method '$METHOD': blkdiscard"
      ;;
    wipefs)
      command_exists wipefs || die "Required command not found for method '$METHOD': wipefs"
      ;;
  esac
}

settle_udev() {
  udevadm settle || true
}

udev_property() {
  local device="$1"
  local property="$2"

  udevadm info --query=property --name "$device" 2>/dev/null \
    | awk -F= -v key="$property" '$1 == key { print substr($0, length(key) + 2); exit }'
}

extract_lsblk_pair() {
  local line="$1"
  local key="$2"

  sed -nE "s/.*${key}=\"([^\"]*)\".*/\1/p" <<< "$line"
}

usb_disk_candidates() {
  local line
  local name
  local type
  local tran
  local rm
  local hotplug

  while IFS= read -r line; do
    name="$(extract_lsblk_pair "$line" "NAME")"
    type="$(extract_lsblk_pair "$line" "TYPE")"
    tran="$(extract_lsblk_pair "$line" "TRAN")"
    rm="$(extract_lsblk_pair "$line" "RM")"
    hotplug="$(extract_lsblk_pair "$line" "HOTPLUG")"

    [[ -n "$name" ]] || continue
    [[ "$type" == "disk" ]] || continue

    if [[ "$tran" == "usb" || "$rm" == "1" || "$hotplug" == "1" ]]; then
      printf '%s\n' "$name"
    fi
  done < <(lsblk -P -dnpo NAME,TYPE,TRAN,RM,HOTPLUG)
}

device_label() {
  local device="$1"
  local label=""

  label="$(lsblk -dnro LABEL -- "$device" 2>/dev/null | head -n 1 || true)"

  if [[ -z "$label" ]]; then
    label="$(udev_property "$device" ID_FS_LABEL || true)"
  fi

  printf '%s\n' "$label"
}

collect_usb_disk_records() {
  local device
  local usec
  local vendor
  local model
  local label
  local size

  while IFS= read -r device; do
    [[ -n "$device" ]] || continue

    usec="$(udev_property "$device" USEC_INITIALIZED || true)"
    vendor="$(udev_property "$device" ID_VENDOR || true)"
    model="$(udev_property "$device" ID_MODEL || true)"
    label="$(device_label "$device")"
    size="$(lsblk -dnro SIZE -- "$device" 2>/dev/null | head -n 1 || true)"

    if [[ ! "$usec" =~ ^[0-9]+$ ]]; then
      verbose "Missing USEC_INITIALIZED for $device; using 0."
      usec=0
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$usec" "$device" "$size" "$vendor" "$model" "$label"
  done < <(usb_disk_candidates)
}

print_usb_record() {
  local record="$1"
  local usec
  local device
  local size
  local vendor
  local model
  local label

  IFS=$'\t' read -r usec device size vendor model label <<< "$record"

  printf '%s - %s - %s %s' \
    "$device" \
    "${size:-UnknownSize}" \
    "${vendor:-UnknownVendor}" \
    "${model:-UnknownModel}"

  if [[ -n "${label:-}" ]]; then
    printf ' - %s' "$label"
  fi

  printf '\n'
}

select_latest_usb_device() {
  local records
  local selected_record
  local selected_device

  records="$(collect_usb_disk_records | sort -nr -k1,1)"

  if [[ -z "$records" ]]; then
    die "No USB/removable whole-disk devices found."
  fi

  selected_record="$(head -n 1 <<< "$records")"
  selected_device="$(cut -f2 <<< "$selected_record")"

  [[ -n "$selected_device" ]] || die "Could not determine latest USB/removable disk."

  log "Selected latest USB/removable whole-disk device:"
  print_usb_record "$selected_record"

  if [[ "$VERBOSE" -eq 1 ]]; then
    log "All USB/removable whole-disk candidates, newest first:"
    while IFS= read -r record; do
      print_usb_record "$record"
    done <<< "$records"
  fi

  DEVICE="$selected_device"
}

canonicalize_device() {
  DEVICE="$(readlink -f -- "$DEVICE")"

  [[ "$DEVICE" == /dev/* ]] || die "Device must resolve to a /dev path: $DEVICE"
  [[ -b "$DEVICE" ]] || die "Not a block device: $DEVICE"
}

get_lsblk_value() {
  local column="$1"
  lsblk -dnro "$column" -- "$DEVICE" | head -n 1
}

validate_device() {
  local type
  local tran
  local removable
  local readonly

  type="$(get_lsblk_value TYPE)"
  tran="$(get_lsblk_value TRAN || true)"
  removable="$(get_lsblk_value RM || true)"
  readonly="$(get_lsblk_value RO || true)"

  [[ "$type" == "disk" ]] || die "Target must be a whole disk device, not a partition. Got type: $type"

  if [[ "$readonly" == "1" ]]; then
    die "Device is read-only: $DEVICE"
  fi

  if [[ "$ALLOW_NON_USB" -ne 1 ]]; then
    if [[ "$tran" != "usb" && "$removable" != "1" ]]; then
      err "Device does not appear to be USB/removable."
      err "TRAN=${tran:-unknown}, RM=${removable:-unknown}"
      err "Use --allow-non-usb only if you are absolutely certain."
      exit 1
    fi
  fi
}

show_device_info() {
  log "Target device:"
  lsblk -dnpo NAME,SIZE,MODEL,SERIAL,TRAN,RM,RO -- "$DEVICE" || true

  log "Device tree:"
  lsblk -po NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS -- "$DEVICE" || true
}

mounted_children() {
  lsblk -nrpo NAME,MOUNTPOINT -- "$DEVICE" \
    | awk '$2 != "" { print $1 }'
}

handle_mounts() {
  local mounted=()
  local dev

  while IFS= read -r dev; do
    [[ -n "$dev" ]] && mounted+=("$dev")
  done < <(mounted_children)

  if [[ "${#mounted[@]}" -eq 0 ]]; then
    return 0
  fi

  warn "Mounted filesystems found on this device:"
  for dev in "${mounted[@]}"; do
    warn "  $dev"
  done

  if [[ "$UNMOUNT" -ne 1 ]]; then
    die "Unmount the device first, or rerun with --unmount."
  fi

  for dev in "${mounted[@]}"; do
    log "Unmounting $dev"
    run umount -- "$dev"
  done
}

confirm_destruction() {
  local typed_device
  local typed_word

  if [[ "$YES" -eq 1 ]]; then
    warn "--yes supplied; skipping interactive confirmation."
    return 0
  fi

  printf '\n'
  warn "This will permanently erase data on:"
  warn "  $DEVICE"
  warn "Method: $METHOD"

  if [[ "$SELECT_LATEST_USB" -eq 1 ]]; then
    warn "Device was selected automatically with --select-latest-usb."
  fi

  printf '\n'

  read -r -p "Type the exact device path to continue: " typed_device
  [[ "$typed_device" == "$DEVICE" ]] || die "Device confirmation did not match."

  read -r -p "Type ERASE to start: " typed_word
  [[ "$typed_word" == "ERASE" ]] || die "Erase confirmation did not match."
}

wipe_with_dd_stream() {
  local source="$1"
  local size_bytes

  size_bytes="$(blockdev --getsize64 "$DEVICE")"
  [[ "$size_bytes" =~ ^[0-9]+$ ]] || die "Could not determine device size."

  log "Writing ${size_bytes} bytes from ${source} to ${DEVICE}."

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: dd if=%q of=%q bs=%q status=progress conv=fdatasync\n' \
      "$source" "$DEVICE" "$BLOCK_SIZE"
    return 0
  fi

  dd if="$source" of="$DEVICE" bs="$BLOCK_SIZE" status=progress conv=fdatasync
}

erase_device() {
  case "$METHOD" in
    zero)
      wipe_with_dd_stream /dev/zero
      ;;
    random)
      warn "Random overwrite is slow and causes unnecessary flash wear."
      wipe_with_dd_stream /dev/urandom
      ;;
    discard)
      log "Running blkdiscard."
      run blkdiscard --verbose "$DEVICE"
      ;;
    secure-discard)
      log "Running blkdiscard --secure."
      warn "This only works if the device supports secure discard."
      run blkdiscard --secure --verbose "$DEVICE"
      ;;
    wipefs)
      warn "wipefs removes signatures only; it does not erase the underlying data."
      run wipefs --all "$DEVICE"
      ;;
  esac
}

reread_partition_table() {
  log "Synchronizing writes."
  run sync

  log "Asking kernel to reread partition table."
  if ! run blockdev --rereadpt "$DEVICE"; then
    warn "Could not reread partition table. Replugging the USB device may be necessary."
  fi
}

main() {
  parse_args "$@"
  require_root
  check_commands
  settle_udev

  if [[ "$SELECT_LATEST_USB" -eq 1 ]]; then
    select_latest_usb_device
  fi

  canonicalize_device
  validate_device
  show_device_info
  handle_mounts
  confirm_destruction
  erase_device
  reread_partition_table

  ok "Erase operation completed."
}

main "$@"