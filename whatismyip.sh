#!/usr/bin/env bash
#
# whatismyip.sh
#
# Purpose:
#   Show public IPv4/IPv6 addresses as observed by multiple external providers,
#   plus the local source address selected by the kernel routing table.
#
# Description:
#   This is a small network diagnostic helper. It compares DNS-based providers,
#   HTTPS-based providers, and local routing information.
#
#   ipify is treated as a normal HTTPS provider, not as a fallback. This is
#   intentional: comparing DNS and HTTPS views can reveal VPN, proxy, split
#   tunnel, DNS egress, or IPv4/IPv6 asymmetry issues.
#
# Output model:
#   Text mode:
#     Default:
#       Human-readable diagnostic sections.
#
#     -q / --quiet:
#       Only resolved public IP value(s), one per line.
#
#     --verbose:
#       Runtime progress messages on stderr.
#
#   JSON mode:
#     --json:
#       Result-focused JSON only. No mixed text output.
#
#     --json -q:
#       Minimal JSON containing only available public IP keys.
#
#     --json --debug:
#       Diagnostic JSON containing metadata, selected options, provider labels,
#       provider statuses, and warnings.
#
#     --verbose:
#       Ignored for JSON shape. Use --debug for diagnostic JSON.
#
# Providers:
#   IPv4:
#     - OpenDNS resolver: myip.opendns.com
#     - Google DNS TXT: o-o.myaddr.l.google.com
#     - ipify HTTPS: https://api.ipify.org
#     - local route source address
#
#   IPv6:
#     - Google DNS TXT: o-o.myaddr.l.google.com
#       First tries IPv6 transport, then default transport if needed.
#     - ipify HTTPS:
#       First tries api6.ipify.org over IPv6, then api64.ipify.org and accepts
#       it only if it returns IPv6.
#     - local route source address
#
# Requirements:
#   bash, dig, ip
#
# Optional:
#   curl, jq, timeout
#
# Version:
#   1.3.0
#
# Date:
#   2026-07-03
#

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.3.0"

CHECK_IPV4=1
CHECK_IPV6=1
USE_IPIFY=1
JSON_OUTPUT=0
QUIET=0
VERBOSE=0
DEBUG=0
TIMEOUT_SECONDS=8

IPV4_OPENDNS=""
IPV4_GOOGLE_DNS=""
IPV4_IPIFY=""
IPV4_LOCAL_ROUTE=""

IPV6_GOOGLE_DNS=""
IPV6_IPIFY=""
IPV6_LOCAL_ROUTE=""

IPV4_OPENDNS_STATUS="not_run"
IPV4_GOOGLE_DNS_STATUS="not_run"
IPV4_IPIFY_STATUS="not_run"
IPV4_LOCAL_ROUTE_STATUS="not_run"

IPV6_GOOGLE_DNS_STATUS="not_run"
IPV6_IPIFY_STATUS="not_run"
IPV6_LOCAL_ROUTE_STATUS="not_run"

WARNINGS=()

usage() {
  cat <<USAGE
${SCRIPT_NAME} ${SCRIPT_VERSION}

Show public IPv4/IPv6 addresses using multiple providers.

Usage:
  ${SCRIPT_NAME} [options]

Options:
  -4, --ipv4
      Check IPv4 only.

  -6, --ipv6
      Check IPv6 only.

  --json
      Print JSON output only.

      Default JSON is result-focused and includes only the enabled address
      families.

  -q, --quiet
      Text mode:
        Print only resolved public IP value(s), one per line.

      JSON mode:
        Print minimal JSON with only available public IP keys.
        Example:
          {"ipv4":"203.0.113.10"}
        or:
          {"ipv4":"203.0.113.10","ipv6":"2001:db8::10"}

  --debug
      Include diagnostic details.

      Text mode:
        Currently equivalent to enabling verbose runtime diagnostics.

      JSON mode:
        Output diagnostic JSON with script metadata, selected options,
        provider labels, provider statuses, and warnings.

  --verbose
      Text mode only:
        Show runtime progress messages on stderr.

      JSON mode:
        Does not change JSON shape. Use --debug for diagnostic JSON.

  --no-ipify
      Disable ipify HTTPS provider.

  --no-curl-fallback
      Backward-compatible alias for --no-ipify.
      Deprecated: ipify is no longer treated as a fallback.

  --no-https
      Alias for --no-ipify.

  --timeout SECONDS
      Timeout for provider lookups.
      Default: ${TIMEOUT_SECONDS}

  -h, --help
      Show this help.

  --version
      Show version information.

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} -4
  ${SCRIPT_NAME} -6

  ${SCRIPT_NAME} -q
  ${SCRIPT_NAME} -4 -q
  ${SCRIPT_NAME} -6 -q

  ${SCRIPT_NAME} --json
  ${SCRIPT_NAME} --json -4
  ${SCRIPT_NAME} --json -6

  ${SCRIPT_NAME} --json -q
  ${SCRIPT_NAME} --json -4 -q
  ${SCRIPT_NAME} --json -6 -q

  ${SCRIPT_NAME} --json --debug
  ${SCRIPT_NAME} --json --debug -4
  ${SCRIPT_NAME} --json --debug -6

  ${SCRIPT_NAME} --verbose
  ${SCRIPT_NAME} --no-ipify
  ${SCRIPT_NAME} --timeout 3

Notes:
  - ipify HTTPS is a normal provider, not a fallback.
  - Provider disagreement is reported as a warning in normal text output.
  - In JSON mode, stdout is always JSON only.
  - In JSON mode, warnings are included only with --debug.
  - Quiet mode suppresses warnings and diagnostic sections.
  - Local route source address is not necessarily your public IP; it is the
    address your host would use as the source for outbound traffic.
  - If IPv6 is disabled or unavailable, IPv6 providers report unavailable.
  - Failed providers should not abort the script.

USAGE
}

log() {
  if [[ "$VERBOSE" -eq 1 && "$JSON_OUTPUT" -eq 0 && "$QUIET" -eq 0 ]]; then
    printf 'INFO: %s\n' "$*" >&2
  fi
}

warn() {
  WARNINGS+=("$*")

  if [[ "$QUIET" -eq 0 && "$JSON_OUTPUT" -eq 0 ]]; then
    printf 'WARN: %s\n' "$*" >&2
  fi
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -4|--ipv4)
        CHECK_IPV4=1
        CHECK_IPV6=0
        shift
        ;;
      -6|--ipv6)
        CHECK_IPV4=0
        CHECK_IPV6=1
        shift
        ;;
      --json)
        JSON_OUTPUT=1
        shift
        ;;
      -q|--quiet)
        QUIET=1
        shift
        ;;
      --debug)
        DEBUG=1
        shift
        ;;
      --verbose)
        VERBOSE=1
        shift
        ;;
      --no-ipify|--no-curl-fallback|--no-https)
        USE_IPIFY=0
        shift
        ;;
      --timeout)
        TIMEOUT_SECONDS="${2:-}"
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
      -*)
        die "Unknown option: $1"
        ;;
      *)
        die "Unexpected argument: $1"
        ;;
    esac
  done

  [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || die "--timeout must be a positive integer."
  [[ "$TIMEOUT_SECONDS" -gt 0 ]] || die "--timeout must be greater than zero."

  if [[ "$DEBUG" -eq 1 && "$JSON_OUTPUT" -eq 0 ]]; then
    VERBOSE=1
  fi
}

require_base_commands() {
  command_exists dig || die "Required command not found: dig"
  command_exists ip || die "Required command not found: ip"

  if [[ "$JSON_OUTPUT" -eq 1 ]]; then
    command_exists jq || die "jq is required for --json output."
  fi

  if [[ "$USE_IPIFY" -eq 1 ]] && ! command_exists curl; then
    warn "curl not found; ipify HTTPS provider disabled."
    USE_IPIFY=0
  fi

  if ! command_exists timeout; then
    warn "timeout command not found; provider commands may take longer to fail."
  fi
}

run_with_timeout() {
  local output=""
  local rc=0

  set +e

  if command_exists timeout; then
    output="$(timeout "$TIMEOUT_SECONDS" "$@" 2>/dev/null)"
    rc=$?
  else
    output="$("$@" 2>/dev/null)"
    rc=$?
  fi

  set -e

  if [[ "$rc" -ne 0 ]]; then
    log "Provider command failed or timed out: $*"
  fi

  printf '%s\n' "$output"

  # Provider failure must not abort the script. Callers validate output and set
  # provider status to unavailable when no usable IP-looking value was returned.
  return 0
}

clean_ip_output() {
  sed \
    -e 's/^"//' \
    -e 's/"$//' \
    -e 's/[[:space:]]//g' \
    -e '/^$/d'
}

first_clean_line_or_empty() {
  clean_ip_output | head -n 1 || true
}

is_ipv4() {
  local value="$1"

  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
  local value="$1"

  [[ "$value" == *:* ]] && [[ "$value" =~ ^[0-9A-Fa-f:.]+$ ]]
}

query_ipv4_opendns() {
  local value=""

  log "Querying IPv4 via OpenDNS."

  value="$(
    run_with_timeout \
      dig +short +time="$TIMEOUT_SECONDS" +tries=1 myip.opendns.com @resolver1.opendns.com A |
      first_clean_line_or_empty
  )"

  if [[ -n "$value" ]] && is_ipv4 "$value"; then
    IPV4_OPENDNS="$value"
    IPV4_OPENDNS_STATUS="ok"
  else
    IPV4_OPENDNS_STATUS="unavailable"
  fi
}

query_ipv4_google_dns() {
  local value=""

  log "Querying IPv4 via Google DNS TXT."

  value="$(
    run_with_timeout \
      dig +short +time="$TIMEOUT_SECONDS" +tries=1 TXT o-o.myaddr.l.google.com @ns1.google.com -4 |
      first_clean_line_or_empty
  )"

  if [[ -n "$value" ]] && is_ipv4 "$value"; then
    IPV4_GOOGLE_DNS="$value"
    IPV4_GOOGLE_DNS_STATUS="ok"
  else
    IPV4_GOOGLE_DNS_STATUS="unavailable"
  fi
}

query_ipv4_ipify() {
  local value=""

  if [[ "$USE_IPIFY" -eq 0 ]]; then
    IPV4_IPIFY_STATUS="skipped"
    return 0
  fi

  log "Querying IPv4 via ipify HTTPS."

  value="$(
    run_with_timeout \
      curl -fsSL --ipv4 --max-time "$TIMEOUT_SECONDS" https://api.ipify.org |
      first_clean_line_or_empty
  )"

  if [[ -n "$value" ]] && is_ipv4 "$value"; then
    IPV4_IPIFY="$value"
    IPV4_IPIFY_STATUS="ok"
  else
    IPV4_IPIFY_STATUS="unavailable"
  fi
}

query_ipv4_local_route() {
  local value=""

  log "Querying IPv4 local route source."

  value="$(
    {
      ip -4 route get 1.1.1.1 2>/dev/null || true
    } |
      awk '
        {
          for (i = 1; i <= NF; i++) {
            if ($i == "src" && (i + 1) <= NF) {
              print $(i + 1)
              exit
            }
          }
        }
      ' |
      first_clean_line_or_empty
  )"

  if [[ -n "$value" ]] && is_ipv4 "$value"; then
    IPV4_LOCAL_ROUTE="$value"
    IPV4_LOCAL_ROUTE_STATUS="ok"
  else
    IPV4_LOCAL_ROUTE_STATUS="unavailable"
  fi
}

query_ipv6_google_dns() {
  local value=""

  log "Querying IPv6 via Google DNS TXT."

  value="$(
    run_with_timeout \
      dig +short +time="$TIMEOUT_SECONDS" +tries=1 TXT o-o.myaddr.l.google.com @ns1.google.com -6 |
      first_clean_line_or_empty
  )"

  if [[ -z "$value" ]] || ! is_ipv6 "$value"; then
    value="$(
      run_with_timeout \
        dig +short +time="$TIMEOUT_SECONDS" +tries=1 TXT o-o.myaddr.l.google.com @ns1.google.com |
        first_clean_line_or_empty
    )"
  fi

  if [[ -n "$value" ]] && is_ipv6 "$value"; then
    IPV6_GOOGLE_DNS="$value"
    IPV6_GOOGLE_DNS_STATUS="ok"
  else
    IPV6_GOOGLE_DNS_STATUS="unavailable"
  fi
}

query_ipv6_ipify() {
  local value=""

  if [[ "$USE_IPIFY" -eq 0 ]]; then
    IPV6_IPIFY_STATUS="skipped"
    return 0
  fi

  log "Querying IPv6 via ipify HTTPS."

  value="$(
    run_with_timeout \
      curl -fsSL --ipv6 --max-time "$TIMEOUT_SECONDS" https://api6.ipify.org |
      first_clean_line_or_empty
  )"

  if [[ -z "$value" ]] || ! is_ipv6 "$value"; then
    value="$(
      run_with_timeout \
        curl -fsSL --max-time "$TIMEOUT_SECONDS" https://api64.ipify.org |
        first_clean_line_or_empty
    )"
  fi

  if [[ -n "$value" ]] && is_ipv6 "$value"; then
    IPV6_IPIFY="$value"
    IPV6_IPIFY_STATUS="ok"
  else
    IPV6_IPIFY_STATUS="unavailable"
  fi
}

query_ipv6_local_route() {
  local value=""

  log "Querying IPv6 local route source."

  value="$(
    {
      ip -6 route get 2001:4860:4860::8888 2>/dev/null || true
    } |
      awk '
        {
          for (i = 1; i <= NF; i++) {
            if ($i == "src" && (i + 1) <= NF) {
              print $(i + 1)
              exit
            }
          }
        }
      ' |
      first_clean_line_or_empty
  )"

  if [[ -n "$value" ]] && is_ipv6 "$value"; then
    IPV6_LOCAL_ROUTE="$value"
    IPV6_LOCAL_ROUTE_STATUS="ok"
  else
    IPV6_LOCAL_ROUTE_STATUS="unavailable"
  fi
}

collect_ipv4() {
  if [[ "$CHECK_IPV4" -eq 0 ]]; then
    return 0
  fi

  query_ipv4_opendns
  query_ipv4_google_dns
  query_ipv4_ipify
  query_ipv4_local_route
}

collect_ipv6() {
  if [[ "$CHECK_IPV6" -eq 0 ]]; then
    return 0
  fi

  query_ipv6_google_dns
  query_ipv6_ipify
  query_ipv6_local_route
}

public_ipv4_values() {
  local -a values=()

  [[ -n "$IPV4_OPENDNS" ]] && values+=("$IPV4_OPENDNS")
  [[ -n "$IPV4_GOOGLE_DNS" ]] && values+=("$IPV4_GOOGLE_DNS")
  [[ -n "$IPV4_IPIFY" ]] && values+=("$IPV4_IPIFY")

  if [[ "${#values[@]}" -gt 0 ]]; then
    printf '%s\n' "${values[@]}" | sort -u
  fi

  return 0
}

public_ipv6_values() {
  local -a values=()

  [[ -n "$IPV6_GOOGLE_DNS" ]] && values+=("$IPV6_GOOGLE_DNS")
  [[ -n "$IPV6_IPIFY" ]] && values+=("$IPV6_IPIFY")

  if [[ "${#values[@]}" -gt 0 ]]; then
    printf '%s\n' "${values[@]}" | sort -u
  fi

  return 0
}

first_public_ipv4() {
  public_ipv4_values | head -n 1 || true
}

first_public_ipv6() {
  public_ipv6_values | head -n 1 || true
}

count_lines() {
  sed '/^$/d' | wc -l | awk '{print $1}'
}

assess_consistency() {
  local ipv4_count=0
  local ipv6_count=0

  if [[ "$CHECK_IPV4" -eq 1 ]]; then
    ipv4_count="$(public_ipv4_values | count_lines || true)"

    if [[ "$ipv4_count" -gt 1 ]]; then
      warn "IPv4 providers disagree."
    elif [[ "$ipv4_count" -eq 0 ]]; then
      warn "No public IPv4 address could be determined."
    fi
  fi

  if [[ "$CHECK_IPV6" -eq 1 ]]; then
    ipv6_count="$(public_ipv6_values | count_lines || true)"

    if [[ "$ipv6_count" -gt 1 ]]; then
      warn "IPv6 providers disagree."
    elif [[ "$ipv6_count" -eq 0 ]]; then
      warn "No public IPv6 address could be determined."
    fi
  fi
}

status_value_text() {
  local value="$1"
  local status="$2"

  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$status"
  fi
}

print_text_ipv4() {
  local result
  local count

  if [[ "$CHECK_IPV4" -eq 0 ]]; then
    return 0
  fi

  result="$(first_public_ipv4)"
  count="$(public_ipv4_values | count_lines || true)"

  printf 'IPv4\n'
  printf '====\n'
  printf '  OpenDNS:         %s\n' "$(status_value_text "$IPV4_OPENDNS" "$IPV4_OPENDNS_STATUS")"
  printf '  Google DNS TXT:  %s\n' "$(status_value_text "$IPV4_GOOGLE_DNS" "$IPV4_GOOGLE_DNS_STATUS")"
  printf '  ipify HTTPS:     %s\n' "$(status_value_text "$IPV4_IPIFY" "$IPV4_IPIFY_STATUS")"
  printf '  Local route:     %s\n' "$(status_value_text "$IPV4_LOCAL_ROUTE" "$IPV4_LOCAL_ROUTE_STATUS")"
  printf '\n'

  if [[ -n "$result" ]]; then
    printf '  Public IPv4:     %s\n' "$result"

    if [[ "$count" -eq 1 ]]; then
      printf '  Status:          consistent\n'
    else
      printf '  Status:          provider mismatch\n'
    fi
  else
    printf '  Public IPv4:     unavailable\n'
    printf '  Status:          unavailable\n'
  fi

  printf '\n'
}

print_text_ipv6() {
  local result
  local count

  if [[ "$CHECK_IPV6" -eq 0 ]]; then
    return 0
  fi

  result="$(first_public_ipv6)"
  count="$(public_ipv6_values | count_lines || true)"

  printf 'IPv6\n'
  printf '====\n'
  printf '  Google DNS TXT:  %s\n' "$(status_value_text "$IPV6_GOOGLE_DNS" "$IPV6_GOOGLE_DNS_STATUS")"
  printf '  ipify HTTPS:     %s\n' "$(status_value_text "$IPV6_IPIFY" "$IPV6_IPIFY_STATUS")"
  printf '  Local route:     %s\n' "$(status_value_text "$IPV6_LOCAL_ROUTE" "$IPV6_LOCAL_ROUTE_STATUS")"
  printf '\n'

  if [[ -n "$result" ]]; then
    printf '  Public IPv6:     %s\n' "$result"

    if [[ "$count" -eq 1 ]]; then
      printf '  Status:          consistent\n'
    else
      printf '  Status:          provider mismatch\n'
    fi
  else
    printf '  Public IPv6:     unavailable\n'
    printf '  Status:          unavailable\n'
  fi

  printf '\n'
}

print_quiet_text() {
  local ipv4_public=""
  local ipv6_public=""

  if [[ "$CHECK_IPV4" -eq 1 ]]; then
    ipv4_public="$(first_public_ipv4)"
    [[ -n "$ipv4_public" ]] && printf '%s\n' "$ipv4_public"
  fi

  if [[ "$CHECK_IPV6" -eq 1 ]]; then
    ipv6_public="$(first_public_ipv6)"
    [[ -n "$ipv6_public" ]] && printf '%s\n' "$ipv6_public"
  fi
}

json_array_from_lines() {
  jq -R . | jq -s .
}

print_quiet_json() {
  local ipv4_public=""
  local ipv6_public=""

  if [[ "$CHECK_IPV4" -eq 1 ]]; then
    ipv4_public="$(first_public_ipv4)"
  fi

  if [[ "$CHECK_IPV6" -eq 1 ]]; then
    ipv6_public="$(first_public_ipv6)"
  fi

  jq -n \
    --arg ipv4 "$ipv4_public" \
    --arg ipv6 "$ipv6_public" \
    '
      {}
      + (if $ipv4 != "" then {ipv4: $ipv4} else {} end)
      + (if $ipv6 != "" then {ipv6: $ipv6} else {} end)
    '
}

print_result_json() {
  local ipv4_public_values_json="[]"
  local ipv6_public_values_json="[]"
  local ipv4_public=""
  local ipv6_public=""

  if [[ "$CHECK_IPV4" -eq 1 ]]; then
    ipv4_public_values_json="$(public_ipv4_values | json_array_from_lines)"
    ipv4_public="$(first_public_ipv4)"
  fi

  if [[ "$CHECK_IPV6" -eq 1 ]]; then
    ipv6_public_values_json="$(public_ipv6_values | json_array_from_lines)"
    ipv6_public="$(first_public_ipv6)"
  fi

  jq -n \
    --argjson checkIpv4 "$CHECK_IPV4" \
    --argjson checkIpv6 "$CHECK_IPV6" \
    --arg ipv4OpenDns "$IPV4_OPENDNS" \
    --arg ipv4GoogleDns "$IPV4_GOOGLE_DNS" \
    --arg ipv4Ipify "$IPV4_IPIFY" \
    --arg ipv4LocalRoute "$IPV4_LOCAL_ROUTE" \
    --arg ipv4Public "$ipv4_public" \
    --arg ipv6GoogleDns "$IPV6_GOOGLE_DNS" \
    --arg ipv6Ipify "$IPV6_IPIFY" \
    --arg ipv6LocalRoute "$IPV6_LOCAL_ROUTE" \
    --arg ipv6Public "$ipv6_public" \
    --argjson ipv4PublicValues "$ipv4_public_values_json" \
    --argjson ipv6PublicValues "$ipv6_public_values_json" \
    '
      {}
      + (
          if $checkIpv4 == 1 then
            {
              ipv4: {
                public: (if $ipv4Public == "" then null else $ipv4Public end),
                values: $ipv4PublicValues,
                providers: {
                  openDns: (if $ipv4OpenDns == "" then null else $ipv4OpenDns end),
                  googleDnsTxt: (if $ipv4GoogleDns == "" then null else $ipv4GoogleDns end),
                  ipifyHttps: (if $ipv4Ipify == "" then null else $ipv4Ipify end),
                  localRoute: (if $ipv4LocalRoute == "" then null else $ipv4LocalRoute end)
                },
                consistent: ($ipv4PublicValues | length <= 1)
              }
            }
          else
            {}
          end
        )
      + (
          if $checkIpv6 == 1 then
            {
              ipv6: {
                public: (if $ipv6Public == "" then null else $ipv6Public end),
                values: $ipv6PublicValues,
                providers: {
                  googleDnsTxt: (if $ipv6GoogleDns == "" then null else $ipv6GoogleDns end),
                  ipifyHttps: (if $ipv6Ipify == "" then null else $ipv6Ipify end),
                  localRoute: (if $ipv6LocalRoute == "" then null else $ipv6LocalRoute end)
                },
                consistent: ($ipv6PublicValues | length <= 1)
              }
            }
          else
            {}
          end
        )
    '
}

print_debug_json() {
  local ipv4_public_values_json="[]"
  local ipv6_public_values_json="[]"
  local warnings_json="[]"
  local ipv4_public=""
  local ipv6_public=""

  if [[ "$CHECK_IPV4" -eq 1 ]]; then
    ipv4_public_values_json="$(public_ipv4_values | json_array_from_lines)"
    ipv4_public="$(first_public_ipv4)"
  fi

  if [[ "$CHECK_IPV6" -eq 1 ]]; then
    ipv6_public_values_json="$(public_ipv6_values | json_array_from_lines)"
    ipv6_public="$(first_public_ipv6)"
  fi

  if [[ "${#WARNINGS[@]}" -gt 0 ]]; then
    warnings_json="$(printf '%s\n' "${WARNINGS[@]}" | jq -R . | jq -s .)"
  fi

  jq -n \
    --arg script "$SCRIPT_NAME" \
    --arg version "$SCRIPT_VERSION" \
    --argjson checkIpv4 "$CHECK_IPV4" \
    --argjson checkIpv6 "$CHECK_IPV6" \
    --argjson useIpify "$USE_IPIFY" \
    --argjson quiet "$QUIET" \
    --argjson verbose "$VERBOSE" \
    --argjson debug "$DEBUG" \
    --arg timeoutSeconds "$TIMEOUT_SECONDS" \
    --arg ipv4OpenDns "$IPV4_OPENDNS" \
    --arg ipv4OpenDnsStatus "$IPV4_OPENDNS_STATUS" \
    --arg ipv4GoogleDns "$IPV4_GOOGLE_DNS" \
    --arg ipv4GoogleDnsStatus "$IPV4_GOOGLE_DNS_STATUS" \
    --arg ipv4Ipify "$IPV4_IPIFY" \
    --arg ipv4IpifyStatus "$IPV4_IPIFY_STATUS" \
    --arg ipv4LocalRoute "$IPV4_LOCAL_ROUTE" \
    --arg ipv4LocalRouteStatus "$IPV4_LOCAL_ROUTE_STATUS" \
    --arg ipv4Public "$ipv4_public" \
    --arg ipv6GoogleDns "$IPV6_GOOGLE_DNS" \
    --arg ipv6GoogleDnsStatus "$IPV6_GOOGLE_DNS_STATUS" \
    --arg ipv6Ipify "$IPV6_IPIFY" \
    --arg ipv6IpifyStatus "$IPV6_IPIFY_STATUS" \
    --arg ipv6LocalRoute "$IPV6_LOCAL_ROUTE" \
    --arg ipv6LocalRouteStatus "$IPV6_LOCAL_ROUTE_STATUS" \
    --arg ipv6Public "$ipv6_public" \
    --argjson ipv4PublicValues "$ipv4_public_values_json" \
    --argjson ipv6PublicValues "$ipv6_public_values_json" \
    --argjson warnings "$warnings_json" \
    '
      {
        script: {
          name: $script,
          version: $version
        },
        options: {
          checkIpv4: ($checkIpv4 == 1),
          checkIpv6: ($checkIpv6 == 1),
          useIpify: ($useIpify == 1),
          quiet: ($quiet == 1),
          verbose: ($verbose == 1),
          debug: ($debug == 1),
          timeoutSeconds: ($timeoutSeconds | tonumber)
        }
      }
      + (
          if $checkIpv4 == 1 then
            {
              ipv4: {
                public: (if $ipv4Public == "" then null else $ipv4Public end),
                values: $ipv4PublicValues,
                providers: {
                  openDns: {
                    label: "OpenDNS",
                    value: (if $ipv4OpenDns == "" then null else $ipv4OpenDns end),
                    status: $ipv4OpenDnsStatus
                  },
                  googleDnsTxt: {
                    label: "Google DNS TXT",
                    value: (if $ipv4GoogleDns == "" then null else $ipv4GoogleDns end),
                    status: $ipv4GoogleDnsStatus
                  },
                  ipifyHttps: {
                    label: "ipify HTTPS",
                    value: (if $ipv4Ipify == "" then null else $ipv4Ipify end),
                    status: $ipv4IpifyStatus
                  },
                  localRoute: {
                    label: "Local route",
                    value: (if $ipv4LocalRoute == "" then null else $ipv4LocalRoute end),
                    status: $ipv4LocalRouteStatus
                  }
                },
                consistent: ($ipv4PublicValues | length <= 1)
              }
            }
          else
            {}
          end
        )
      + (
          if $checkIpv6 == 1 then
            {
              ipv6: {
                public: (if $ipv6Public == "" then null else $ipv6Public end),
                values: $ipv6PublicValues,
                providers: {
                  googleDnsTxt: {
                    label: "Google DNS TXT",
                    value: (if $ipv6GoogleDns == "" then null else $ipv6GoogleDns end),
                    status: $ipv6GoogleDnsStatus
                  },
                  ipifyHttps: {
                    label: "ipify HTTPS",
                    value: (if $ipv6Ipify == "" then null else $ipv6Ipify end),
                    status: $ipv6IpifyStatus
                  },
                  localRoute: {
                    label: "Local route",
                    value: (if $ipv6LocalRoute == "" then null else $ipv6LocalRoute end),
                    status: $ipv6LocalRouteStatus
                  }
                },
                consistent: ($ipv6PublicValues | length <= 1)
              }
            }
          else
            {}
          end
        )
      + {
          warnings: $warnings
        }
    '
}

print_text() {
  print_text_ipv4
  print_text_ipv6
}

main() {
  parse_args "$@"
  require_base_commands

  collect_ipv4
  collect_ipv6
  assess_consistency

  if [[ "$JSON_OUTPUT" -eq 1 && "$QUIET" -eq 1 ]]; then
    print_quiet_json
  elif [[ "$JSON_OUTPUT" -eq 1 && "$DEBUG" -eq 1 ]]; then
    print_debug_json
  elif [[ "$JSON_OUTPUT" -eq 1 ]]; then
    print_result_json
  elif [[ "$QUIET" -eq 1 ]]; then
    print_quiet_text
  else
    print_text
  fi
}

main "$@"