#!/usr/bin/env bash
#
# gpg-secret-key-summary.sh
#
# Purpose:
#   Print a safe summary of locally available GPG secret keys.
#
# Description:
#   Lists secret keys in the current GnuPG home and prints:
#     - User ID
#     - Long key ID
#     - Full fingerprint
#
#   This script does not export private key material. It only lists metadata for
#   keys where a secret key is available.
#
# Security note:
#   A fingerprint is not secret, but it identifies your key. Treat output as
#   mildly sensitive when sharing logs or screenshots.
#
# Implementation:
#   Uses GnuPG machine-readable --with-colons output instead of parsing the
#   human-readable key listing.
#
# Requirements:
#   bash, gpg
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

YES=0
QUIET=0
VERBOSE=0
PRINT_ALL=0
RAW_COLONS=0
GNUPGHOME_OVERRIDE=""

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
  [[ "$QUIET" -eq 0 ]] && printf '%s\n' "${C_BLUE}INFO:${C_RESET} $*"
}

warn() {
  printf '%s\n' "${C_YELLOW}WARN:${C_RESET} $*" >&2
}

err() {
  printf '%s\n' "${C_RED}ERROR:${C_RESET} $*" >&2
}

ok() {
  [[ "$QUIET" -eq 0 ]] && printf '%s\n' "${C_GREEN}OK:${C_RESET} $*"
}

verbose() {
  [[ "$VERBOSE" -eq 1 ]] && log "$*"
}

usage() {
  cat <<USAGE
${SCRIPT_NAME} ${SCRIPT_VERSION}

Print a safe summary of locally available GPG secret keys.

Usage:
  ${SCRIPT_NAME} [options]

Options:
  --all
      Print all secret key summaries without prompting.

  -y, --yes
      Same as --all.

  --raw-colons
      Print raw gpg --with-colons output.
      Useful for debugging.

  --gnupghome DIR
      Use an explicit GnuPG home directory.

  --quiet
      Reduce informational output.

  --verbose
      Print extra details.

  -h, --help
      Show this help.

  --version
      Show version information.

Examples:
  ${SCRIPT_NAME}

  ${SCRIPT_NAME} --all

  ${SCRIPT_NAME} --gnupghome ~/.gnupg --all

  ${SCRIPT_NAME} --raw-colons

Notes:
  This script does not export secret key material.
  It only lists metadata for keys where secret keys are present.

USAGE
}

die() {
  err "$*"
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

confirm() {
  local prompt="$1"
  local response

  if [[ "$YES" -eq 1 || "$PRINT_ALL" -eq 1 ]]; then
    return 0
  fi

  read -r -p "$prompt [y/N] " response
  response="${response,,}"

  [[ "$response" =~ ^(y|yes)$ ]]
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)
        PRINT_ALL=1
        shift
        ;;
      -y|--yes)
        YES=1
        PRINT_ALL=1
        shift
        ;;
      --raw-colons)
        RAW_COLONS=1
        shift
        ;;
      --gnupghome)
        GNUPGHOME_OVERRIDE="${2:-}"
        shift 2
        ;;
      --quiet)
        QUIET=1
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
      -*)
        err "Unknown option: $1"
        usage >&2
        exit 2
        ;;
      *)
        err "Unexpected argument: $1"
        usage >&2
        exit 2
        ;;
    esac
  done

  if [[ -n "$GNUPGHOME_OVERRIDE" ]]; then
    [[ -d "$GNUPGHOME_OVERRIDE" ]] || die "GnuPG home directory does not exist: $GNUPGHOME_OVERRIDE"
    export GNUPGHOME="$GNUPGHOME_OVERRIDE"
  fi
}

check_requirements() {
  command_exists gpg || die "Required command not found: gpg"
}

list_secret_keys_colons() {
  gpg \
    --batch \
    --list-secret-keys \
    --keyid-format=long \
    --with-colons \
    --fingerprint
}

print_raw_colons() {
  list_secret_keys_colons
}

print_key_block() {
  local keyid="$1"
  local fingerprint="$2"
  local uid="$3"

  printf 'User ID:     %s\n' "$uid"
  printf 'Key ID:      %s\n' "$keyid"
  printf 'Fingerprint: %s\n' "$fingerprint"
  printf '\n'
}

print_secret_key_summaries() {
  local line
  local record_type
  local keyid=""
  local fingerprint=""
  local primary_uid=""
  local secret_key_count=0

  while IFS= read -r line; do
    record_type="${line%%:*}"

    case "$record_type" in
      sec)
        if [[ -n "$keyid" ]]; then
          secret_key_count=$((secret_key_count + 1))

          if confirm "Print GPG key ${primary_uid:-$keyid}?"; then
            print_key_block "$keyid" "$fingerprint" "${primary_uid:-unknown UID}"
          fi
        fi

        keyid="$(awk -F: '{ print $5 }' <<< "$line")"
        fingerprint=""
        primary_uid=""
        ;;

      fpr)
        if [[ -z "$fingerprint" ]]; then
          fingerprint="$(awk -F: '{ print $10 }' <<< "$line")"
        fi
        ;;

      uid)
        if [[ -z "$primary_uid" ]]; then
          primary_uid="$(awk -F: '{ print $10 }' <<< "$line")"
        fi
        ;;
    esac
  done < <(list_secret_keys_colons)

  if [[ -n "$keyid" ]]; then
    secret_key_count=$((secret_key_count + 1))

    if confirm "Print GPG key ${primary_uid:-$keyid}?"; then
      print_key_block "$keyid" "$fingerprint" "${primary_uid:-unknown UID}"
    fi
  fi

  if [[ "$secret_key_count" -eq 0 ]]; then
    warn "No secret keys found."
    return 1
  fi

  verbose "Secret keys found: $secret_key_count"
}
main() {
  parse_args "$@"
  check_requirements

  if [[ -n "${GNUPGHOME:-}" ]]; then
    verbose "Using GNUPGHOME=$GNUPGHOME"
  fi

  if [[ "$RAW_COLONS" -eq 1 ]]; then
    print_raw_colons
  else
    print_secret_key_summaries
  fi
}

main "$@"