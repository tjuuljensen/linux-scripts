#!/usr/bin/env bash
#
# whatismyip.sh
#
# Purpose:
#   Display the current public egress IP address and the local source address
#   selected by the system routing table.
#
# Description:
#   This script queries external DNS-based "what is my IP" mechanisms and
#   compares the results. It also shows the local source address the kernel
#   would use for outbound IPv4/IPv6 traffic.
#
# Public IP methods:
#   - OpenDNS:
#       dig +short myip.opendns.com A @resolver1.opendns.com
#
#   - Google:
#       dig +short TXT o-o.myaddr.l.google.com @ns1.google.com
#
# Notes:
#   Different providers may report different addresses when VPNs, split
#   tunnels, DNS proxies, CGNAT, IPv6, resolver forwarding, or anonymizing
#   services are involved. A mismatch is useful diagnostic information, not
#   automatically an error.
#
# Requirements:
#   bash, dig, ip, grep, sed, awk
#
# Optional:
#   curl
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

IP_FAMILY="both"
QUIET=0
JSON=0
USE_CURL_FALLBACK=1
TIMEOUT=3

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

usage() {
  cat <<USAGE
${SCRIPT_NAME} ${SCRIPT_VERSION}

Show public egress IP address and local route source address.

Usage:
  ${SCRIPT_NAME} [options]

Options:
  -4, --ipv4
      Show IPv4 only.

  -6, --ipv6
      Show IPv6 only.

  --json
      Print JSON output.

  -q, --quiet
      Print only the best public IP address.
      For --ipv4 or --ipv6 this prints one address if available.

  --no-curl-fallback
      Do not use HTTPS fallback services if DNS lookup fails.

  --timeout SECONDS
      Timeout for DNS/HTTP lookups.
      Default: 3

  -h, --help
      Show this help.

  --version
      Show version information.

Examples:
  ${SCRIPT_NAME}

  ${SCRIPT_NAME} --ipv4

  ${SCRIPT_NAME} --ipv6

  ${SCRIPT_NAME} --quiet --ipv4

  ${SCRIPT_NAME} --json

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
      -4|--ipv4)
        IP_FAMILY="ipv4"
        shift
        ;;
      -6|--ipv6)
        IP_FAMILY="ipv6"
        shift
        ;;
      --json)
        JSON=1
        shift
        ;;
      -q|--quiet)
        QUIET=1
        shift
        ;;
      --no-curl-fallback)
        USE_CURL_FALLBACK=0
        shift
        ;;
      --timeout)
        TIMEOUT="${2:-}"
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
        err "Unknown argument: $1"
        usage >&2
        exit 2
        ;;
    esac
  done

  if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT" -lt 1 ]]; then
    die "--timeout must be a positive integer."
  fi
}

check_requirements() {
  local cmd

  for cmd in dig ip grep sed awk; do
    command_exists "$cmd" || die "Required command not found: $cmd"
  done

  if [[ "$USE_CURL_FALLBACK" -eq 1 ]] && ! command_exists curl; then
    warn "curl not found; HTTPS fallback disabled."
    USE_CURL_FALLBACK=0
  fi
}

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
  [[ "$1" == *:* && "$1" =~ ^[0-9A-Fa-f:]+$ ]]
}

first_ipv4_from_text() {
  grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '
    {
      split($0, o, ".")
      if (o[1] <= 255 && o[2] <= 255 && o[3] <= 255 && o[4] <= 255) {
        print
        exit
      }
    }
  '
}

first_ipv6_from_text() {
  grep -Eio '([0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}' | head -n 1
}

dig_timeout_args() {
  printf '+time=%s\n+tries=1\n' "$TIMEOUT"
}

query_opendns_ipv4() {
  dig +short "+time=${TIMEOUT}" +tries=1 myip.opendns.com A @resolver1.opendns.com 2>/dev/null \
    | first_ipv4_from_text || true
}

query_google_ipv4() {
  dig +short "+time=${TIMEOUT}" +tries=1 TXT o-o.myaddr.l.google.com @ns1.google.com 2>/dev/null \
    | sed 's/"//g' \
    | first_ipv4_from_text || true
}

query_google_ipv6() {
  dig -6 +short "+time=${TIMEOUT}" +tries=1 TXT o-o.myaddr.l.google.com @ns1.google.com 2>/dev/null \
    | sed 's/"//g' \
    | first_ipv6_from_text || true
}

curl_public_ipv4() {
  [[ "$USE_CURL_FALLBACK" -eq 1 ]] || return 0

  curl -4 -fsS --max-time "$TIMEOUT" https://api.ipify.org 2>/dev/null \
    | first_ipv4_from_text || true
}

curl_public_ipv6() {
  [[ "$USE_CURL_FALLBACK" -eq 1 ]] || return 0

  curl -6 -fsS --max-time "$TIMEOUT" https://api64.ipify.org 2>/dev/null \
    | first_ipv6_from_text || true
}

local_route_ipv4() {
  ip -4 route get 1.1.1.1 2>/dev/null \
    | sed -n 's/.* src \([^ ]*\).*/\1/p' \
    | head -n 1 || true
}

local_route_ipv6() {
  ip -6 route get 2606:4700:4700::1111 2>/dev/null \
    | sed -n 's/.* src \([^ ]*\).*/\1/p' \
    | head -n 1 || true
}

best_public_ip() {
  local primary="$1"
  local secondary="$2"
  local fallback="$3"

  if [[ -n "$primary" ]]; then
    printf '%s\n' "$primary"
  elif [[ -n "$secondary" ]]; then
    printf '%s\n' "$secondary"
  elif [[ -n "$fallback" ]]; then
    printf '%s\n' "$fallback"
  fi
}

json_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g'
}

print_json() {
  local opendns_v4="$1"
  local google_v4="$2"
  local curl_v4="$3"
  local local_v4="$4"
  local google_v6="$5"
  local curl_v6="$6"
  local local_v6="$7"
  local best_v4
  local best_v6

  best_v4="$(best_public_ip "$opendns_v4" "$google_v4" "$curl_v4")"
  best_v6="$(best_public_ip "$google_v6" "$curl_v6" "")"

  cat <<JSON
{
  "ipv4": {
    "public": "$(printf '%s' "$best_v4" | json_escape)",
    "opendns": "$(printf '%s' "$opendns_v4" | json_escape)",
    "google": "$(printf '%s' "$google_v4" | json_escape)",
    "curl_fallback": "$(printf '%s' "$curl_v4" | json_escape)",
    "local_route_source": "$(printf '%s' "$local_v4" | json_escape)"
  },
  "ipv6": {
    "public": "$(printf '%s' "$best_v6" | json_escape)",
    "google": "$(printf '%s' "$google_v6" | json_escape)",
    "curl_fallback": "$(printf '%s' "$curl_v6" | json_escape)",
    "local_route_source": "$(printf '%s' "$local_v6" | json_escape)"
  }
}
JSON
}

print_human() {
  local opendns_v4="$1"
  local google_v4="$2"
  local curl_v4="$3"
  local local_v4="$4"
  local google_v6="$5"
  local curl_v6="$6"
  local local_v6="$7"

  local best_v4
  local best_v6

  best_v4="$(best_public_ip "$opendns_v4" "$google_v4" "$curl_v4")"
  best_v6="$(best_public_ip "$google_v6" "$curl_v6" "")"

  if [[ "$IP_FAMILY" == "ipv4" || "$IP_FAMILY" == "both" ]]; then
    printf 'IPv4 public:              %s\n' "${best_v4:-Unavailable}"
    printf 'IPv4 local route source:  %s\n' "${local_v4:-Unavailable}"

    if [[ -n "$opendns_v4" || -n "$google_v4" || -n "$curl_v4" ]]; then
      printf 'IPv4 checks:\n'
      printf '  OpenDNS:               %s\n' "${opendns_v4:-Unavailable}"
      printf '  Google:                %s\n' "${google_v4:-Unavailable}"
      printf '  HTTPS fallback:         %s\n' "${curl_v4:-Unavailable}"
    fi

    if [[ -n "$opendns_v4" && -n "$google_v4" && "$opendns_v4" != "$google_v4" ]]; then
      warn "OpenDNS and Google reported different IPv4 addresses."
    fi
  fi

  if [[ "$IP_FAMILY" == "both" ]]; then
    printf '\n'
  fi

  if [[ "$IP_FAMILY" == "ipv6" || "$IP_FAMILY" == "both" ]]; then
    printf 'IPv6 public:              %s\n' "${best_v6:-Unavailable}"
    printf 'IPv6 local route source:  %s\n' "${local_v6:-Unavailable}"

    if [[ -n "$google_v6" || -n "$curl_v6" ]]; then
      printf 'IPv6 checks:\n'
      printf '  Google:                %s\n' "${google_v6:-Unavailable}"
      printf '  HTTPS fallback:         %s\n' "${curl_v6:-Unavailable}"
    fi
  fi
}

main() {
  parse_args "$@"
  check_requirements

  local opendns_v4=""
  local google_v4=""
  local curl_v4=""
  local local_v4=""
  local google_v6=""
  local curl_v6=""
  local local_v6=""

  if [[ "$IP_FAMILY" == "ipv4" || "$IP_FAMILY" == "both" ]]; then
    opendns_v4="$(query_opendns_ipv4)"
    google_v4="$(query_google_ipv4)"
    curl_v4="$(curl_public_ipv4)"
    local_v4="$(local_route_ipv4)"
  fi

  if [[ "$IP_FAMILY" == "ipv6" || "$IP_FAMILY" == "both" ]]; then
    google_v6="$(query_google_ipv6)"
    curl_v6="$(curl_public_ipv6)"
    local_v6="$(local_route_ipv6)"
  fi

  if [[ "$QUIET" -eq 1 ]]; then
    case "$IP_FAMILY" in
      ipv4)
        best_public_ip "$opendns_v4" "$google_v4" "$curl_v4"
        ;;
      ipv6)
        best_public_ip "$google_v6" "$curl_v6" ""
        ;;
      both)
        best_public_ip "$opendns_v4" "$google_v4" "$curl_v4"
        ;;
    esac
    exit 0
  fi

  if [[ "$JSON" -eq 1 ]]; then
    print_json \
      "$opendns_v4" \
      "$google_v4" \
      "$curl_v4" \
      "$local_v4" \
      "$google_v6" \
      "$curl_v6" \
      "$local_v6"
  else
    print_human \
      "$opendns_v4" \
      "$google_v4" \
      "$curl_v4" \
      "$local_v4" \
      "$google_v6" \
      "$curl_v6" \
      "$local_v6"
  fi
}

main "$@"