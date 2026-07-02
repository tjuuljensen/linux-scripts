#!/usr/bin/env bash
#
# latest-usb-disk.sh
#
# Purpose:
#   Print the most recently initialized USB/removable whole-disk block device.
#
# Description:
#   This script lists whole-disk block devices, filters for devices that appear
#   to be USB or removable, reads udev properties for each candidate, and prints
#   the newest one based on USEC_INITIALIZED.
#
#   It is intended as a safer replacement for parsing "dmesg | tail" when you
#   want to identify the USB disk that was most recently attached.
#
# Output:
#   Default:
#     /dev/sdX - Vendor Model - Label
#
#   With --plain:
#     /dev/sdX
#
# Safety:
#   This script only identifies a likely device. It does not erase, format,
#   mount, unmount, or modify anything.
#
# Requirements:
#   bash, lsblk, udevadm, awk, sort
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
LIST_ALL=0
VERBOSE=0

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
else
  C_RESET=""
  C_RED=""
  C_YELLOW=""
  C_BLUE=""
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

Print the most recently initialized USB/removable whole-disk device.

Usage:
  ${SCRIPT_NAME} [options]

Options:
  --plain
      Print only the device path, for example:
        /dev/sdb

  --list
      List all detected USB/removable whole-disk devices, newest first.

  --verbose
      Print extra diagnostic information.

  -h, --help
      Show this help.

  --version
      Show version information.

Examples:
  ${SCRIPT_NAME}

  ${SCRIPT_NAME} --plain

  ${SCRIPT_NAME} --list

Notes:
  This script uses lsblk and udev properties instead of parsing dmesg.
  It only reports candidate devices. Always verify before destructive actions.

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
      --list)
        LIST_ALL=1
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

  for cmd in lsblk udevadm awk sort; do
    command_exists "$cmd" || die "Required command not found: $cmd"
  done
}

udev_property() {
  local device="$1"
  local property="$2"

  udevadm info --query=property --name "$device" 2>/dev/null \
    | awk -F= -v key="$property" '$1 == key { print substr($0, length(key) + 2); exit }'
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

device_candidates() {
  local line
  local name=""
  local type=""
  local tran=""
  local rm=""
  local hotplug=""

  while IFS= read -r line; do
    name=""
    type=""
    tran=""
    rm=""
    hotplug=""

    # lsblk -P emits KEY="VALUE" pairs, which avoids column-position problems
    # when TRAN is empty.
    eval "$line"

    [[ "$type" == "disk" ]] || continue

    if [[ "$tran" == "usb" || "$rm" == "1" || "$hotplug" == "1" ]]; then
      printf '%s\n' "$name"
    fi
  done < <(lsblk -P -dnpo NAME,TYPE,TRAN,RM,HOTPLUG)
}

collect_devices() {
  local device
  local usec
  local vendor
  local model
  local label

  while IFS= read -r device; do
    [[ -n "$device" ]] || continue

    usec="$(udev_property "$device" USEC_INITIALIZED || true)"
    vendor="$(udev_property "$device" ID_VENDOR || true)"
    model="$(udev_property "$device" ID_MODEL || true)"
    label="$(device_label "$device")"

    # Fall back to zero if the udev timestamp is missing.
    if [[ ! "$usec" =~ ^[0-9]+$ ]]; then
      verbose "Missing USEC_INITIALIZED for $device; using 0."
      usec=0
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$usec" "$device" "$vendor" "$model" "$label"
  done < <(device_candidates)
}

print_record() {
  local record="$1"
  local usec device vendor model label

  IFS=$'\t' read -r usec device vendor model label <<< "$record"

  if [[ "$PLAIN" -eq 1 ]]; then
    printf '%s\n' "$device"
  else
    printf '%s - %s %s' "$device" "${vendor:-UnknownVendor}" "${model:-UnknownModel}"

    if [[ -n "${label:-}" ]]; then
      printf ' - %s' "$label"
    fi

    printf '\n'
  fi
}

main() {
  parse_args "$@"
  check_requirements

  local records
  records="$(collect_devices | sort -nr -k1,1)"

  if [[ -z "$records" ]]; then
    die "No USB/removable whole-disk devices found."
  fi

  if [[ "$LIST_ALL" -eq 1 ]]; then
    while IFS= read -r record; do
      print_record "$record"
    done <<< "$records"
  else
    print_record "$(head -n 1 <<< "$records")"
  fi
}

main "$@"