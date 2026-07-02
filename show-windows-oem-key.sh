#!/usr/bin/env bash
#
# show-windows-oem-key.sh
#
# Purpose:
#   Read the embedded OEM Windows product key from the ACPI MSDM firmware table
#   on systems that expose one.
#
# Description:
#   Some OEM Windows systems store a product key in the firmware ACPI MSDM table.
#   On Linux, that table is commonly exposed at:
#
#     /sys/firmware/acpi/tables/MSDM
#
#   This script extracts a Windows product-key-looking value from that table.
#
# Safety:
#   A Windows product key is sensitive licensing information. By default, this
#   script prints a masked key. Use --show only when you intentionally want the
#   full key displayed in the terminal.
#
# Requirements:
#   bash, strings, grep
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

MSDM_TABLE="/sys/firmware/acpi/tables/MSDM"
SHOW_FULL=0

usage() {
  cat <<USAGE
${SCRIPT_NAME} ${SCRIPT_VERSION}

Read the embedded OEM Windows product key from the ACPI MSDM firmware table.

Usage:
  ${SCRIPT_NAME} [options]

Options:
  --show
      Print the full product key.
      Default is masked output.

  --table PATH
      Read from a specific MSDM table path.
      Default: /sys/firmware/acpi/tables/MSDM

  -h, --help
      Show this help.

  --version
      Show version information.

Examples:
  ${SCRIPT_NAME}

  ${SCRIPT_NAME} --show

Notes:
  If no MSDM table exists, this system probably does not expose an embedded
  OEM Windows product key through ACPI firmware.

USAGE
}

error() {
  printf 'ERROR: %s\n' "$*" >&2
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --show)
        SHOW_FULL=1
        shift
        ;;
      --table)
        MSDM_TABLE="${2:-}"
        shift 2
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
        error "Unknown argument: $1"
        usage >&2
        exit 2
        ;;
    esac
  done
}

check_requirements() {
  command -v strings >/dev/null 2>&1 || {
    error "Required command not found: strings"
    exit 1
  }

  command -v grep >/dev/null 2>&1 || {
    error "Required command not found: grep"
    exit 1
  }
}

read_msdm_strings() {
  if [[ ! -e "$MSDM_TABLE" ]]; then
    error "MSDM table not found: $MSDM_TABLE"
    error "This system may not have an embedded OEM Windows key."
    exit 1
  fi

  if [[ -r "$MSDM_TABLE" ]]; then
    strings "$MSDM_TABLE"
  else
    sudo strings "$MSDM_TABLE"
  fi
}

extract_key() {
  read_msdm_strings \
    | grep -Eo '[A-Z0-9]{5}(-[A-Z0-9]{5}){4}' \
    | head -n 1
}

mask_key() {
  local key="$1"

  # Example:
  # XXXXX-XXXXX-XXXXX-XXXXX-AB123
  printf 'XXXXX-XXXXX-XXXXX-XXXXX-%s\n' "${key##*-}"
}

main() {
  parse_args "$@"
  check_requirements

  local key
  key="$(extract_key || true)"

  if [[ -z "$key" ]]; then
    error "No Windows product-key-looking value found in MSDM table."
    exit 1
  fi

  if [[ "$SHOW_FULL" -eq 1 ]]; then
    printf '%s\n' "$key"
  else
    mask_key "$key"
    printf 'Use --show to print the full key.\n' >&2
  fi
}

main "$@"