#!/usr/bin/env bash
#
# rpm-list-keys.sh
#
# Purpose:
#   List public GPG/OpenPGP keys imported into the RPM database.
#
# Description:
#   RPM stores imported package-signing public keys as gpg-pubkey entries in
#   the RPM database. This script lists those keys in a readable format.
#
#   By default, it uses rpm's traditional gpg-pubkey query output. If requested,
#   it can use rpmkeys --list to show fingerprint-oriented output.
#
# Scope:
#   This script only reports keys imported into the RPM database. It does not
#   verify whether the keys are still expected, still valid for your enabled
#   repositories, or safe to keep.
#
# Requirements:
#   rpm
#
# Optional:
#   rpmkeys
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

MODE="rpm"
VERBOSE=0

usage() {
  cat <<USAGE
${SCRIPT_NAME} ${SCRIPT_VERSION}

List public keys imported into the RPM database.

Usage:
  ${SCRIPT_NAME} [options]

Options:
  --mode rpm|rpmkeys
      rpm      Use rpm -q gpg-pubkey query output.
      rpmkeys  Use rpmkeys --list fingerprint-oriented output.
      Default: rpm

  --rpmkeys
      Shortcut for --mode rpmkeys.

  --verbose
      Print explanatory notes.

  -h, --help
      Show this help.

  --version
      Show version information.

Examples:
  ${SCRIPT_NAME}

  ${SCRIPT_NAME} --rpmkeys

  ${SCRIPT_NAME} --mode rpm

Notes:
  This lists imported RPM public keys. It does not prove that every listed key
  is still needed or should still be trusted.

USAGE
}

err() {
  printf 'ERROR: %s\n' "$*" >&2
}

log() {
  printf 'INFO: %s\n' "$*"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        MODE="${2:-}"
        shift 2
        ;;
      --rpmkeys)
        MODE="rpmkeys"
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

  case "$MODE" in
    rpm|rpmkeys) ;;
    *)
      err "--mode must be one of: rpm, rpmkeys"
      exit 2
      ;;
  esac
}

list_with_rpm() {
  rpm -q gpg-pubkey --qf '%{NAME}-%{VERSION}-%{RELEASE}\t%{SUMMARY}\n'
}

list_with_rpmkeys() {
  if ! command_exists rpmkeys; then
    err "rpmkeys not found. Use --mode rpm instead."
    exit 1
  fi

  rpmkeys --list
}

main() {
  parse_args "$@"

  command_exists rpm || {
    err "Required command not found: rpm"
    exit 1
  }

  if [[ "$VERBOSE" -eq 1 ]]; then
    log "Listing RPM database public keys."
    log "This does not determine whether the keys are still needed."
  fi

  case "$MODE" in
    rpm)
      list_with_rpm
      ;;
    rpmkeys)
      list_with_rpmkeys
      ;;
  esac
}

main "$@"