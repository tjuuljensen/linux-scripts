#!/usr/bin/env bash
#
# list-usb-disks.sh
#
# Purpose:
#   List currently attached USB/removable whole-disk block devices and show
#   any active dd erase/write commands targeting those devices.
#
# Description:
#   This script is intended as a monitoring companion for erase-usb.sh.
#   It prints USB/removable disks, basic identity information, filesystem labels,
#   mountpoints, and matching running dd commands.
#
# Usage:
#   list-usb-disks.sh
#   watch list-usb-disks.sh
#
# Scope:
#   - Lists whole disk devices only, not individual partitions.
#   - Does not modify, mount, unmount, erase, or format anything.
#   - Detects devices using lsblk TRAN/RM/HOTPLUG information and udev
#     properties instead of grepping dmesg.
#
# Requirements:
#   bash, lsblk, udevadm, awk, pgrep, grep
#
# Author:
#   Torsten Juul-Jensen
#
# Version:
#   1.0.0
#
# Date:
#   2026-07-02

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.0.0"

PLAIN=0
SHOW_ALL=0
INCLUDE_CARD_READERS=0
VERBOSE=0

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

verbose() {
  [[ "$VERBOSE" -eq 1 ]] && log "$*"
}

usage() {
  cat <<USAGE
${SCRIPT_NAME} ${SCRIPT_VERSION}

List attached USB/removable whole-disk devices and active dd jobs.

Usage:
  ${SCRIPT_NAME} [options]

Options:
  --plain
      Print only device paths.

  --all
      Include all removable/hotplug disks, not only USB transport devices.

  --include-card-readers
      Include devices whose model looks like SD/MMC card readers.
      By default, SD_MMC-style readers are hidden to match the old script.

  --verbose
      Print extra diagnostic information.

  -h, --help
      Show this help.

  --version
      Show version information.

Examples:
  ${SCRIPT_NAME}

  ${SCRIPT_NAME} --plain

  ${SCRIPT_NAME} --all

  watch ${SCRIPT_NAME}

USAGE
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
      --plain)
        PLAIN=1
        shift
        ;;
      --all)
        SHOW_ALL=1
        shift
        ;;
      --include-card-readers)
        INCLUDE_CARD_READERS=1
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
}

check_requirements() {
  local cmd

  for cmd in lsblk udevadm awk pgrep grep; do
    command_exists "$cmd" || die "Required command not found: $cmd"
  done
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

device_label() {
  local device="$1"
  local label=""

  label="$(lsblk -dnro LABEL -- "$device" 2>/dev/null | head -n 1 || true)"

  if [[ -z "$label" ]]; then
    label="$(udev_property "$device" ID_FS_LABEL || true)"
  fi

  printf '%s\n' "$label"
}

device_mountpoints() {
  local device="$1"

  lsblk -nrpo MOUNTPOINTS -- "$device" 2>/dev/null \
    | awk 'NF { print }' \
    | paste -sd ',' -
}

running_dd_for_device() {
  local device="$1"

  pgrep -a -x dd 2>/dev/null \
    | grep -F -- "of=${device}" \
    || true
}

is_card_reader_model() {
  local model="$1"

  [[ "$model" =~ SD_MMC|SD/MMC|Card_Reader|Card\ Reader ]]
}

print_header() {
  if [[ "$PLAIN" -eq 1 ]]; then
    return 0
  fi

  printf '%-12s %-10s %-10s %-24s %-18s %-24s %-20s %s\n' \
    "DEVICE" "SIZE" "TRAN" "VENDOR" "MODEL" "LABEL" "MOUNTPOINTS" "DD_JOB"
}

print_device_row() {
  local device="$1"
  local size="$2"
  local tran="$3"
  local vendor="$4"
  local model="$5"
  local label="$6"
  local mountpoints="$7"
  local dd_job="$8"

  if [[ "$PLAIN" -eq 1 ]]; then
    printf '%s\n' "$device"
    return 0
  fi

  printf '%-12s %-10s %-10s %-24s %-18s %-24s %-20s %s\n' \
    "$device" \
    "${size:-?}" \
    "${tran:-?}" \
    "${vendor:-?}" \
    "${model:-?}" \
    "${label:-"-"}" \
    "${mountpoints:-"-"}" \
    "${dd_job:-"-"}"
}

list_devices() {
  local line
  local name
  local type
  local tran
  local rm
  local hotplug
  local size
  local model
  local vendor
  local label
  local mountpoints
  local dd_job
  local found=0

  print_header

  while IFS= read -r line; do
    name="$(extract_lsblk_pair "$line" "NAME")"
    type="$(extract_lsblk_pair "$line" "TYPE")"
    tran="$(extract_lsblk_pair "$line" "TRAN")"
    rm="$(extract_lsblk_pair "$line" "RM")"
    hotplug="$(extract_lsblk_pair "$line" "HOTPLUG")"
    size="$(extract_lsblk_pair "$line" "SIZE")"
    model="$(extract_lsblk_pair "$line" "MODEL")"

    [[ -n "$name" ]] || continue
    [[ "$type" == "disk" ]] || continue

    if [[ "$SHOW_ALL" -eq 1 ]]; then
      [[ "$tran" == "usb" || "$rm" == "1" || "$hotplug" == "1" ]] || continue
    else
      [[ "$tran" == "usb" ]] || continue
    fi

    if [[ "$INCLUDE_CARD_READERS" -ne 1 ]] && is_card_reader_model "$model"; then
      verbose "Skipping card reader-like device: $name $model"
      continue
    fi

    vendor="$(udev_property "$name" ID_VENDOR || true)"
    [[ -n "$vendor" ]] || vendor="$(udev_property "$name" ID_VENDOR_FROM_DATABASE || true)"
    [[ -n "$vendor" ]] || vendor="-"

    label="$(device_label "$name")"
    mountpoints="$(device_mountpoints "$name")"
    dd_job="$(running_dd_for_device "$name")"

    found=1

    print_device_row \
      "$name" \
      "$size" \
      "$tran" \
      "$vendor" \
      "$model" \
      "$label" \
      "$mountpoints" \
      "$dd_job"

  done < <(lsblk -P -dnpo NAME,TYPE,TRAN,RM,HOTPLUG,SIZE,MODEL)
  
  if [[ "$found" -eq 0 && "$PLAIN" -ne 1 ]]; then
    warn "No matching USB/removable whole-disk devices found."
  fi
}

main() {
  parse_args "$@"
  check_requirements
  list_devices
}

main "$@"