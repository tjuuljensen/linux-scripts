#!/usr/bin/env bash
#
# ike-transform-scan.sh
#
# Purpose:
#   Test which IKEv1 Phase 1 transform proposals an IPsec/IKE endpoint accepts.
#
# Description:
#   This script wraps ike-scan and sends a matrix of IKEv1 transform proposals
#   using:
#
#     --trans=enc[/len],hash,auth,group
#
#   It is useful for auditing legacy VPN gateways for accepted combinations of:
#     - Encryption algorithm
#     - Hash/integrity algorithm
#     - Authentication method
#     - Diffie-Hellman group
#
# Important:
#   This is an IKEv1 transform scanner. The ike-scan --trans option is not for
#   IKEv2 transform auditing.
#
# Legal / operational warning:
#   Only scan systems you own or have explicit authorization to test. The default
#   profile sends many UDP/500 IKE probes to each target.
#
# Transform values:
#   Encryption:
#     3des      = 5
#     aes128    = 7/128
#     aes192    = 7/192
#     aes256    = 7/256
#
#   Hash:
#     md5       = 1
#     sha1      = 2
#     sha256    = 5
#     sha384    = 6
#     sha512    = 7
#
#   Authentication:
#     psk       = 1
#     rsa-sig   = 3
#
#   Diffie-Hellman groups:
#     modp768   = 1
#     modp1024  = 2
#     modp1536  = 5
#     modp2048  = 14
#     modp3072  = 15
#     ecp256    = 19
#     ecp384    = 20
#     ecp521    = 21
#
# Requirements:
#   bash, ike-scan, sleep
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

PROFILE="all"
DRY_RUN=0
VERBOSE=0
QUIET=0
DELAY="0"
CSV_FILE=""
SHOW_ONLY_RESPONSES=0

IKE_SCAN_ARGS=()

# Default/all profile. This intentionally includes weak/legacy transforms
# because the purpose is to discover what the remote gateway accepts.
ENCS=()
HASHS=()
GROUPS=()
AUTHS=()

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

Test accepted IKEv1 transform proposals with ike-scan.

Usage:
  ${SCRIPT_NAME} [script options] TARGET [TARGET ...]
  ${SCRIPT_NAME} [script options] -- [ike-scan options] TARGET [TARGET ...]

Script options:
  --profile all|modern|weak
      Transform profile to scan.

      all:
        Original broad scan profile:
          3DES, AES-128, AES-192, AES-256
          MD5, SHA1, SHA256, SHA384, SHA512
          DH groups 1, 2, 5, 14, 15, 19, 20, 21
          PSK and RSA signatures

      modern:
        AES + SHA2 + stronger DH/ECP groups only.

      weak:
        Legacy/weak combinations only:
          3DES, MD5/SHA1, DH groups 1/2/5

      Default: all

  --responses-only
      Suppress ike-scan output for transform attempts that produce no output.

  --delay SECONDS
      Sleep between transform attempts.
      Default: 0

  --csv FILE
      Write one CSV row per transform attempt with return code and output.

  --dry-run
      Print ike-scan commands without executing them.

  --quiet
      Reduce script progress output.

  --verbose
      Print extra details.

  -h, --help
      Show this help.

  --version
      Show version information.

Passing ike-scan options:
  Use -- before ike-scan-specific options.

Examples:
  ${SCRIPT_NAME} 203.0.113.10

  ${SCRIPT_NAME} --profile modern 203.0.113.10

  ${SCRIPT_NAME} --profile weak --delay 0.2 203.0.113.10

  ${SCRIPT_NAME} --dry-run 203.0.113.10

  ${SCRIPT_NAME} --csv ike-results.csv 203.0.113.10

  ${SCRIPT_NAME} -- --sport=500 --dport=500 203.0.113.10

Notes:
  This script uses ike-scan -M and --trans=enc,hash,auth,group.

  The default "all" profile performs:
    4 encryption options
    5 hash options
    8 DH groups
    2 authentication methods

  That is 320 transform attempts per target invocation.

USAGE
}

die() {
  err "$*"
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

csv_escape() {
  local value="$1"

  value="${value//$'\r'/}"
  value="${value//$'\n'/\\n}"
  value="${value//\"/\"\"}"

  printf '"%s"' "$value"
}

csv_write_header() {
  local file="$1"

  if [[ ! -e "$file" || ! -s "$file" ]]; then
    printf 'timestamp,profile,enc_name,enc_value,hash_name,hash_value,auth_name,auth_value,group_name,group_value,trans,return_code,output\n' > "$file"
  fi
}

csv_write_row() {
  local enc_name="$1"
  local enc_value="$2"
  local hash_name="$3"
  local hash_value="$4"
  local auth_name="$5"
  local auth_value="$6"
  local group_name="$7"
  local group_value="$8"
  local trans="$9"
  local rc="${10}"
  local output="${11}"
  local timestamp

  [[ -n "$CSV_FILE" ]] || return 0

  timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"

  {
    csv_escape "$timestamp"; printf ','
    csv_escape "$PROFILE"; printf ','
    csv_escape "$enc_name"; printf ','
    csv_escape "$enc_value"; printf ','
    csv_escape "$hash_name"; printf ','
    csv_escape "$hash_value"; printf ','
    csv_escape "$auth_name"; printf ','
    csv_escape "$auth_value"; printf ','
    csv_escape "$group_name"; printf ','
    csv_escape "$group_value"; printf ','
    csv_escape "$trans"; printf ','
    csv_escape "$rc"; printf ','
    csv_escape "$output"; printf '\n'
  } >> "$CSV_FILE"
}

set_profile() {
  case "$PROFILE" in
    all)
      ENCS=(
        "3des:5"
        "aes128:7/128"
        "aes192:7/192"
        "aes256:7/256"
      )

      HASHS=(
        "md5:1"
        "sha1:2"
        "sha256:5"
        "sha384:6"
        "sha512:7"
      )

      GROUPS=(
        "modp768:1"
        "modp1024:2"
        "modp1536:5"
        "modp2048:14"
        "modp3072:15"
        "ecp256:19"
        "ecp384:20"
        "ecp521:21"
      )

      AUTHS=(
        "psk:1"
        "rsa-sig:3"
      )
      ;;

    modern)
      ENCS=(
        "aes128:7/128"
        "aes192:7/192"
        "aes256:7/256"
      )

      HASHS=(
        "sha256:5"
        "sha384:6"
        "sha512:7"
      )

      GROUPS=(
        "modp2048:14"
        "modp3072:15"
        "ecp256:19"
        "ecp384:20"
        "ecp521:21"
      )

      AUTHS=(
        "psk:1"
        "rsa-sig:3"
      )
      ;;

    weak)
      ENCS=(
        "3des:5"
      )

      HASHS=(
        "md5:1"
        "sha1:2"
      )

      GROUPS=(
        "modp768:1"
        "modp1024:2"
        "modp1536:5"
      )

      AUTHS=(
        "psk:1"
        "rsa-sig:3"
      )
      ;;

    *)
      die "--profile must be one of: all, modern, weak"
      ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        PROFILE="${2:-}"
        shift 2
        ;;
      --responses-only)
        SHOW_ONLY_RESPONSES=1
        shift
        ;;
      --delay)
        DELAY="${2:-}"
        shift 2
        ;;
      --csv)
        CSV_FILE="${2:-}"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        VERBOSE=1
        shift
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
      --)
        shift
        IKE_SCAN_ARGS+=("$@")
        break
        ;;
      --*)
        die "Unknown script option: $1. Use -- before ike-scan-specific long options."
        ;;
      *)
        IKE_SCAN_ARGS+=("$1")
        shift
        ;;
    esac
  done

  [[ "${#IKE_SCAN_ARGS[@]}" -gt 0 ]] || {
    usage >&2
    exit 2
  }

  [[ "$DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--delay must be a non-negative number."
}

check_requirements() {
  command_exists ike-scan || die "Required command not found: ike-scan"
  command_exists sleep || die "Required command not found: sleep"
}

count_attempts() {
  printf '%s\n' "$(( ${#ENCS[@]} * ${#HASHS[@]} * ${#GROUPS[@]} * ${#AUTHS[@]} ))"
}

split_entry() {
  local entry="$1"
  local -n out_name="$2"
  local -n out_value="$3"

  out_name="${entry%%:*}"
  out_value="${entry#*:}"
}

run_transform() {
  local enc_entry="$1"
  local hash_entry="$2"
  local group_entry="$3"
  local auth_entry="$4"

  local enc_name enc_value
  local hash_name hash_value
  local group_name group_value
  local auth_name auth_value
  local trans
  local output
  local rc
  local cmd=()

  split_entry "$enc_entry" enc_name enc_value
  split_entry "$hash_entry" hash_name hash_value
  split_entry "$group_entry" group_name group_value
  split_entry "$auth_entry" auth_name auth_value

  trans="${enc_value},${hash_value},${auth_value},${group_value}"

  cmd=(
    ike-scan
    "--trans=${trans}"
    -M
    "${IKE_SCAN_ARGS[@]}"
  )

  if [[ "$QUIET" -eq 0 ]]; then
    printf '\n'
    printf 'Transform: enc=%s(%s), hash=%s(%s), auth=%s(%s), group=%s(%s)\n' \
      "$enc_name" "$enc_value" \
      "$hash_name" "$hash_value" \
      "$auth_name" "$auth_value" \
      "$group_name" "$group_value"

    printf 'Command:   '
    printf '%q ' "${cmd[@]}"
    printf '\n'
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    csv_write_row \
      "$enc_name" "$enc_value" \
      "$hash_name" "$hash_value" \
      "$auth_name" "$auth_value" \
      "$group_name" "$group_value" \
      "$trans" \
      "dry-run" \
      ""

    return 0
  fi

  set +e
  output="$("${cmd[@]}" 2>&1)"
  rc=$?
  set -e

  csv_write_row \
    "$enc_name" "$enc_value" \
    "$hash_name" "$hash_value" \
    "$auth_name" "$auth_value" \
    "$group_name" "$group_value" \
    "$trans" \
    "$rc" \
    "$output"

  if [[ "$SHOW_ONLY_RESPONSES" -eq 1 ]]; then
    if [[ -n "${output//[[:space:]]/}" ]]; then
      printf '%s\n' "$output"
    fi
  else
    printf '%s\n' "$output"
  fi

  return 0
}

main() {
  parse_args "$@"
  set_profile
  check_requirements

  if [[ -n "$CSV_FILE" ]]; then
    csv_write_header "$CSV_FILE"
    verbose "CSV output: $CSV_FILE"
  fi

  log "Profile: $PROFILE"
  log "Transform attempts per ike-scan invocation: $(count_attempts)"
  log "ike-scan arguments: ${IKE_SCAN_ARGS[*]}"

  if [[ "$PROFILE" == "all" || "$PROFILE" == "weak" ]]; then
    warn "This profile includes weak/legacy transforms. That is useful for auditing, but do not treat acceptance as acceptable configuration."
  fi

  local enc
  local hash
  local group
  local auth

  for enc in "${ENCS[@]}"; do
    for hash in "${HASHS[@]}"; do
      for group in "${GROUPS[@]}"; do
        for auth in "${AUTHS[@]}"; do
          run_transform "$enc" "$hash" "$group" "$auth"

          if [[ "$DELAY" != "0" && "$DRY_RUN" -eq 0 ]]; then
            sleep "$DELAY"
          fi
        done
      done
    done
  done

  ok "Scan completed."
}

main "$@"