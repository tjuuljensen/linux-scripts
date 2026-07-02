#!/usr/bin/env bash
#
# whois-rdap.sh
#
# Purpose:
#   Collect and normalize WHOIS and RDAP registration data for domains,
#   subdomains, IPv4 addresses, and IPv6 addresses.
#
# Description:
#   This is a registration-data triage helper. It normalizes the input target,
#   detects whether it is a domain or IP address, queries WHOIS and RDAP, and
#   prints a concise normalized summary by default.
#
#   Optional --save mode stores raw WHOIS/RDAP evidence in a timestamped output
#   directory for incident response notes, abuse/takedown work, or audit trails.
#
#   This script does not perform reputation checks, passive DNS, CT-log lookup,
#   screenshotting, web crawling, or infrastructure clustering.
#
# Requirements:
#   bash, whois, curl, jq, python3, grep, awk, sed, sort, date
#
# Version:
#   1.4.0
#
# Date:
#   2026-07-02
#
# Notes:
#   - RDAP is queried through the configured RDAP bootstrap/base service.
#   - WHOIS and RDAP can disagree. Treat both as evidence, not absolute truth.
#   - Stop/station/domain IDs and registration records can change over time.
#

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.4.0"

TARGET=""
TARGET_TYPE=""
NORMALIZED_TARGET=""
BASE_DOMAIN=""
BASE_DOMAIN_OVERRIDE=""

OUTPUT_DIR=""
SAVE_OUTPUT=0
RAW_OUTPUT=0
FORMAT="text"
QUIET=0
VERBOSE=0
NO_COLOR=0
NO_HINTS=0
NO_WHOIS=0
NO_RDAP=0
RIR_ALL=0
DRY_RUN=0

RDAP_BASE_URL="https://rdap.org"
MAX_REFERRALS=3
WHOIS_TIMEOUT=25
RDAP_HTTP_TIMEOUT=30
RDAP_HTTP_RETRIES=1

C_RESET=""
C_RED=""
C_GREEN=""
C_YELLOW=""
C_CYAN=""
C_BOLD=""

WHOIS_TEXT=""
RDAP_JSON=""
WHOIS_STATUS="not_run"
RDAP_STATUS="not_run"
RDAP_ERROR=""

WHOIS_FILES=()
RDAP_FILE=""

usage() {
  cat <<USAGE
${SCRIPT_NAME} ${SCRIPT_VERSION}

Collect and normalize WHOIS/RDAP registration data.

Usage:
  ${SCRIPT_NAME} [options] <domain|subdomain|ipv4|ipv6|url>

Examples:
  ${SCRIPT_NAME} example.com
  ${SCRIPT_NAME} www.example.com
  ${SCRIPT_NAME} https://www.example.com/path?q=1
  ${SCRIPT_NAME} 8.8.8.8
  ${SCRIPT_NAME} 2001:4860:4860::8888

  ${SCRIPT_NAME} --save example.com
  ${SCRIPT_NAME} --format json example.com
  ${SCRIPT_NAME} --raw --save example.com
  ${SCRIPT_NAME} --no-whois example.com
  ${SCRIPT_NAME} --no-rdap example.com
  ${SCRIPT_NAME} --base-domain example.co.uk www.mail.example.co.uk

Options:
  --output-dir DIR
      Directory for saved raw evidence.
      Default when --save is used:
        ./whois-rdap-output/<target>-<timestamp>

  --save
      Save raw WHOIS and RDAP responses to files.

  --raw
      Print raw collected WHOIS/RDAP data instead of only normalized summary.

  --format text|json
      Output format.
      Default: text

  --base-domain DOMAIN
      Override detected registrable/base domain.

  --rdap-bootstrap URL
      RDAP base/bootstrap service.
      Default: ${RDAP_BASE_URL}

  --max-referrals N
      Maximum WHOIS referral depth.
      Default: ${MAX_REFERRALS}

  --whois-timeout SECONDS
      Timeout for each WHOIS command.
      Default: ${WHOIS_TIMEOUT}

  --rdap-timeout SECONDS
      RDAP HTTP timeout.
      Default: ${RDAP_HTTP_TIMEOUT}

  --rdap-retries N
      RDAP HTTP retries.
      Default: ${RDAP_HTTP_RETRIES}

  --rir-all
      For IP targets, query all major RIR WHOIS servers in addition to the
      default whois lookup.

  --no-whois
      Skip WHOIS collection.

  --no-rdap
      Skip RDAP collection.

  --no-hints
      Suppress explanatory hints in text output.

  --dry-run
      Show what would be queried/saved without making network calls.

  --quiet
      Suppress progress messages.

  --verbose
      Show extra diagnostics.

  --no-color
      Disable ANSI color output.

  -h, --help
      Show this help.

  --version
      Show version information.

Notes:
  - Default output is normalized text printed to stdout.
  - --save writes raw evidence files but still prints the normalized summary.
  - WHOIS and RDAP can differ; collect both when accuracy matters.
  - RDAP support varies by TLD/registry and IP allocation.

USAGE
}

init_colors() {
  if [[ "$NO_COLOR" -eq 0 && -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[1;33m'
    C_CYAN=$'\033[0;36m'
    C_BOLD=$'\033[1m'
  fi

  return 0
}

log() {
  if [[ "$QUIET" -eq 0 ]]; then
    printf '%s\n' "${C_CYAN}INFO:${C_RESET} $*" >&2
  fi

  return 0
}

ok() {
  if [[ "$QUIET" -eq 0 ]]; then
    printf '%s\n' "${C_GREEN}OK:${C_RESET} $*" >&2
  fi

  return 0
}

warn() {
  if [[ "$QUIET" -eq 0 ]]; then
    printf '%s\n' "${C_YELLOW}WARN:${C_RESET} $*" >&2
  fi

  return 0
}

err() {
  printf '%s\n' "${C_RED}ERROR:${C_RESET} $*" >&2
  return 0
}

verbose() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    log "$*"
  fi

  return 0
}

die() {
  err "$*"
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_command() {
  local cmd="$1"
  command_exists "$cmd" || die "Required command not found: $cmd"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output-dir)
        OUTPUT_DIR="${2:-}"
        shift 2
        ;;
      --save)
        SAVE_OUTPUT=1
        shift
        ;;
      --raw)
        RAW_OUTPUT=1
        shift
        ;;
      --format)
        FORMAT="${2:-}"
        shift 2
        ;;
      --base-domain)
        BASE_DOMAIN_OVERRIDE="${2:-}"
        shift 2
        ;;
      --rdap-bootstrap)
        RDAP_BASE_URL="${2:-}"
        shift 2
        ;;
      --max-referrals)
        MAX_REFERRALS="${2:-}"
        shift 2
        ;;
      --whois-timeout)
        WHOIS_TIMEOUT="${2:-}"
        shift 2
        ;;
      --rdap-timeout)
        RDAP_HTTP_TIMEOUT="${2:-}"
        shift 2
        ;;
      --rdap-retries)
        RDAP_HTTP_RETRIES="${2:-}"
        shift 2
        ;;
      --rir-all)
        RIR_ALL=1
        shift
        ;;
      --no-whois)
        NO_WHOIS=1
        shift
        ;;
      --no-rdap)
        NO_RDAP=1
        shift
        ;;
      --no-hints)
        NO_HINTS=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
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
      --no-color)
        NO_COLOR=1
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
        die "Unknown option: $1"
        ;;
      *)
        if [[ -n "$TARGET" ]]; then
          die "Only one target may be supplied. Unexpected argument: $1"
        fi
        TARGET="$1"
        shift
        ;;
    esac
  done

  [[ -n "$TARGET" ]] || {
    usage >&2
    exit 2
  }

  case "$FORMAT" in
    text|json)
      ;;
    *)
      die "--format must be one of: text, json"
      ;;
  esac

  [[ "$MAX_REFERRALS" =~ ^[0-9]+$ ]] || die "--max-referrals must be a non-negative integer."
  [[ "$WHOIS_TIMEOUT" =~ ^[0-9]+$ ]] || die "--whois-timeout must be a non-negative integer."
  [[ "$RDAP_HTTP_TIMEOUT" =~ ^[0-9]+$ ]] || die "--rdap-timeout must be a non-negative integer."
  [[ "$RDAP_HTTP_RETRIES" =~ ^[0-9]+$ ]] || die "--rdap-retries must be a non-negative integer."

  if [[ "$NO_WHOIS" -eq 1 && "$NO_RDAP" -eq 1 ]]; then
    die "Both --no-whois and --no-rdap were specified. Nothing to collect."
  fi
}

check_requirements() {
  require_command python3
  require_command jq
  require_command grep
  require_command awk
  require_command sed
  require_command sort
  require_command date

  if [[ "$NO_WHOIS" -eq 0 ]]; then
    require_command whois
  fi

  if [[ "$NO_RDAP" -eq 0 ]]; then
    require_command curl
  fi
}

normalize_target() {
  local result

  result="$(
    python3 - "$TARGET" <<'PY'
import ipaddress
import re
import sys
from urllib.parse import urlparse

raw = sys.argv[1].strip()

if not raw:
    raise SystemExit("ERROR: empty target")

candidate = raw

if "://" in candidate:
    parsed = urlparse(candidate)
    candidate = parsed.hostname or ""
else:
    parsed = urlparse("//" + candidate)
    if parsed.hostname:
        candidate = parsed.hostname

candidate = candidate.strip().strip("[]").strip(".").lower()

if not candidate:
    raise SystemExit("ERROR: could not extract target")

try:
    ip = ipaddress.ip_address(candidate)
    print(f"ip\t{ip.compressed}")
    raise SystemExit(0)
except ValueError:
    pass

if not re.fullmatch(r"[a-z0-9.-]+", candidate):
    raise SystemExit(f"ERROR: unsupported target syntax: {raw}")

if ".." in candidate or "." not in candidate:
    raise SystemExit(f"ERROR: target does not look like a domain or IP: {raw}")

labels = candidate.split(".")

if any(not label or len(label) > 63 for label in labels):
    raise SystemExit(f"ERROR: invalid domain label in target: {raw}")

print(f"domain\t{candidate}")
PY
  )" || die "$result"

  TARGET_TYPE="${result%%$'\t'*}"
  NORMALIZED_TARGET="${result#*$'\t'}"

  verbose "Target type: $TARGET_TYPE"
  verbose "Normalized target: $NORMALIZED_TARGET"
}

detect_base_domain() {
  if [[ "$TARGET_TYPE" != "domain" ]]; then
    BASE_DOMAIN=""
    return 0
  fi

  if [[ -n "$BASE_DOMAIN_OVERRIDE" ]]; then
    BASE_DOMAIN="$BASE_DOMAIN_OVERRIDE"
    return 0
  fi

  BASE_DOMAIN="$(
    python3 - "$NORMALIZED_TARGET" <<'PY'
import sys

domain = sys.argv[1].strip(".").lower()
labels = domain.split(".")

# Lightweight heuristic only. This is not a full public-suffix-list parser.
common_two_label_suffixes = {
    "co.uk", "org.uk", "ac.uk", "gov.uk",
    "com.au", "net.au", "org.au",
    "co.nz", "org.nz",
    "com.br", "com.mx",
    "co.jp", "ne.jp", "or.jp",
    "co.kr", "or.kr",
    "com.tr",
}

if len(labels) < 2:
    print(domain)
    raise SystemExit(0)

last_two = ".".join(labels[-2:])
last_three = ".".join(labels[-3:])

if len(labels) >= 3 and last_two in common_two_label_suffixes:
    print(last_three)
else:
    print(last_two)
PY
  )"

  if [[ "$BASE_DOMAIN" != "$NORMALIZED_TARGET" && "$NO_HINTS" -eq 0 && "$QUIET" -eq 0 ]]; then
    warn "Using heuristic base domain: $BASE_DOMAIN"
    warn "Use --base-domain if this is wrong."
  fi

  return 0
}

safe_filename() {
  python3 - "$1" <<'PY'
import re
import sys

raw = sys.argv[1]
safe = re.sub(r"[^A-Za-z0-9._-]+", "_", raw).strip("_")
print(safe or "target")
PY
}

timestamp_utc() {
  date -u +"%Y%m%dT%H%M%SZ"
}

prepare_output_dir() {
  if [[ "$SAVE_OUTPUT" -eq 0 ]]; then
    return 0
  fi

  if [[ -z "$OUTPUT_DIR" ]]; then
    local safe
    safe="$(safe_filename "$NORMALIZED_TARGET")"
    OUTPUT_DIR="./whois-rdap-output/${safe}-$(timestamp_utc)"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    verbose "Would create output directory: $OUTPUT_DIR"
    return 0
  fi

  mkdir -p -- "$OUTPUT_DIR"
}

save_text_file() {
  local path="$1"
  local content="$2"

  if [[ "$SAVE_OUTPUT" -eq 0 ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    verbose "Would save: $path"
    return 0
  fi

  printf '%s\n' "$content" > "$path"
}

run_whois_command() {
  local args=("$@")
  local output=""
  local rc=0

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: whois %s\n' "${args[*]}"
    return 0
  fi

  set +e
  if command_exists timeout; then
    output="$(timeout "$WHOIS_TIMEOUT" whois "${args[@]}" 2>&1)"
    rc=$?
  else
    output="$(whois "${args[@]}" 2>&1)"
    rc=$?
  fi
  set -e

  printf '%s\n' "$output"
  return "$rc"
}

extract_whois_referral_server() {
  local text="$1"

  printf '%s\n' "$text" |
    awk '
      BEGIN { IGNORECASE=1 }
      /^Registrar WHOIS Server:/ {
        sub(/^[^:]+:[[:space:]]*/, "", $0)
        print
        exit
      }
      /^Whois Server:/ {
        sub(/^[^:]+:[[:space:]]*/, "", $0)
        print
        exit
      }
      /^ReferralServer:/ {
        sub(/^[^:]+:[[:space:]]*/, "", $0)
        gsub(/^whois:\/\//, "", $0)
        print
        exit
      }
    ' |
    sed 's/[[:space:]]*$//' |
    head -n 1
}

collect_whois_domain() {
  local query="$1"
  local current_query="$query"
  local seen_servers=""
  local referral=""
  local text=""
  local combined=""
  local depth=0
  local file=""

  log "Collecting WHOIS for domain: $query"

  text="$(run_whois_command "$current_query" || true)"
  combined+=$'===== WHOIS default =====\n'
  combined+="$text"
  combined+=$'\n'

  if [[ "$SAVE_OUTPUT" -eq 1 ]]; then
    file="${OUTPUT_DIR}/whois-default.txt"
    save_text_file "$file" "$text"
    WHOIS_FILES+=("$file")
  fi

  referral="$(extract_whois_referral_server "$text")"

  while [[ -n "$referral" && "$depth" -lt "$MAX_REFERRALS" ]]; do
    if grep -Fqx -- "$referral" <<< "$seen_servers"; then
      verbose "Skipping repeated WHOIS referral server: $referral"
      break
    fi

    seen_servers+="${referral}"$'\n'
    depth=$((depth + 1))

    log "Following WHOIS referral ${depth}/${MAX_REFERRALS}: $referral"

    text="$(run_whois_command -h "$referral" "$query" || true)"

    combined+=$'\n'
    combined+="===== WHOIS referral: ${referral} ====="
    combined+=$'\n'
    combined+="$text"
    combined+=$'\n'

    if [[ "$SAVE_OUTPUT" -eq 1 ]]; then
      file="${OUTPUT_DIR}/whois-referral-${depth}-$(safe_filename "$referral").txt"
      save_text_file "$file" "$text"
      WHOIS_FILES+=("$file")
    fi

    referral="$(extract_whois_referral_server "$text")"
  done

  WHOIS_TEXT="$combined"
  WHOIS_STATUS="collected"
}

collect_whois_ip_default() {
  local ip="$1"
  local text=""
  local file=""

  log "Collecting WHOIS for IP: $ip"

  text="$(run_whois_command "$ip" || true)"

  WHOIS_TEXT+=$'===== WHOIS default =====\n'
  WHOIS_TEXT+="$text"
  WHOIS_TEXT+=$'\n'

  if [[ "$SAVE_OUTPUT" -eq 1 ]]; then
    file="${OUTPUT_DIR}/whois-default.txt"
    save_text_file "$file" "$text"
    WHOIS_FILES+=("$file")
  fi

  WHOIS_STATUS="collected"
}

collect_whois_ip_all_rirs() {
  local ip="$1"
  local rir=""
  local text=""
  local file=""
  local rirs=(
    "whois.arin.net"
    "whois.ripe.net"
    "whois.apnic.net"
    "whois.lacnic.net"
    "whois.afrinic.net"
  )

  for rir in "${rirs[@]}"; do
    log "Collecting WHOIS from RIR server: $rir"

    text="$(run_whois_command -h "$rir" "$ip" || true)"

    WHOIS_TEXT+=$'\n'
    WHOIS_TEXT+="===== WHOIS RIR: ${rir} ====="
    WHOIS_TEXT+=$'\n'
    WHOIS_TEXT+="$text"
    WHOIS_TEXT+=$'\n'

    if [[ "$SAVE_OUTPUT" -eq 1 ]]; then
      file="${OUTPUT_DIR}/whois-rir-$(safe_filename "$rir").txt"
      save_text_file "$file" "$text"
      WHOIS_FILES+=("$file")
    fi
  done

  WHOIS_STATUS="collected"
}

collect_whois() {
  if [[ "$NO_WHOIS" -eq 1 ]]; then
    WHOIS_STATUS="skipped"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would collect WHOIS for $NORMALIZED_TARGET"
    WHOIS_STATUS="dry_run"
    return 0
  fi

  if [[ "$TARGET_TYPE" == "domain" ]]; then
    collect_whois_domain "$BASE_DOMAIN"
  else
    collect_whois_ip_default "$NORMALIZED_TARGET"

    if [[ "$RIR_ALL" -eq 1 ]]; then
      collect_whois_ip_all_rirs "$NORMALIZED_TARGET"
    fi
  fi
}

curl_json_to_stdout() {
  local url="$1"
  local output=""
  local rc=0

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '{"dryRun":true,"url":%s}\n' "$(jq -Rn --arg url "$url" '$url')"
    return 0
  fi

  set +e
  output="$(
    curl \
      -fsSL \
      --location \
      --connect-timeout 5 \
      --max-time "$RDAP_HTTP_TIMEOUT" \
      --retry "$RDAP_HTTP_RETRIES" \
      --retry-delay 1 \
      --retry-max-time "$RDAP_HTTP_TIMEOUT" \
      --header "Accept: application/rdap+json, application/json" \
      --user-agent "${SCRIPT_NAME}/${SCRIPT_VERSION}" \
      "$url" \
      2>&1
  )"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    printf '%s\n' "$output" >&2
    return "$rc"
  fi

  printf '%s\n' "$output"
}

collect_rdap() {
  local url=""
  local json=""
  local rc=0

  if [[ "$NO_RDAP" -eq 1 ]]; then
    RDAP_STATUS="skipped"
    return 0
  fi

  if [[ "$TARGET_TYPE" == "domain" ]]; then
    url="${RDAP_BASE_URL%/}/domain/${BASE_DOMAIN}"
  else
    url="${RDAP_BASE_URL%/}/ip/${NORMALIZED_TARGET}"
  fi

  log "Collecting RDAP: $url"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    RDAP_JSON="{\"dryRun\":true,\"url\":\"$url\"}"
    RDAP_STATUS="dry_run"
    return 0
  fi

  set +e
  json="$(curl_json_to_stdout "$url")"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 || -z "$json" ]]; then
    RDAP_STATUS="unavailable"
    RDAP_ERROR="RDAP request failed for ${url}"
    warn "$RDAP_ERROR"
    return 0
  fi

  if ! jq empty >/dev/null 2>&1 <<< "$json"; then
    RDAP_STATUS="invalid_json"
    RDAP_ERROR="RDAP response was not valid JSON"
    warn "$RDAP_ERROR"
    return 0
  fi

  RDAP_JSON="$json"
  RDAP_STATUS="collected"

  if [[ "$SAVE_OUTPUT" -eq 1 ]]; then
    RDAP_FILE="${OUTPUT_DIR}/rdap.json"
    save_text_file "$RDAP_FILE" "$(jq . <<< "$RDAP_JSON")"
  fi
}

json_string_or_null() {
  local value="$1"

  if [[ -z "$value" ]]; then
    printf 'null'
  else
    jq -Rn --arg value "$value" '$value'
  fi
}

whois_field_first() {
  local pattern="$1"

  printf '%s\n' "$WHOIS_TEXT" |
    awk -v pat="$pattern" '
      BEGIN { IGNORECASE=1 }
      $0 ~ pat {
        sub(/^[^:]+:[[:space:]]*/, "", $0)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        if ($0 != "") {
          print
          exit
        }
      }
    '
}

whois_field_all_unique() {
  local pattern="$1"

  printf '%s\n' "$WHOIS_TEXT" |
    awk -v pat="$pattern" '
      BEGIN { IGNORECASE=1 }
      $0 ~ pat {
        sub(/^[^:]+:[[:space:]]*/, "", $0)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        if ($0 != "") print
      }
    ' |
    sort -u
}

rdap_jq_first() {
  local filter="$1"

  if [[ -z "$RDAP_JSON" || "$RDAP_STATUS" != "collected" ]]; then
    return 0
  fi

  jq -r "$filter // empty" <<< "$RDAP_JSON" 2>/dev/null | head -n 1
}

rdap_jq_all_unique() {
  local filter="$1"

  if [[ -z "$RDAP_JSON" || "$RDAP_STATUS" != "collected" ]]; then
    return 0
  fi

  jq -r "$filter // empty" <<< "$RDAP_JSON" 2>/dev/null | sed '/^$/d' | sort -u
}

print_text_summary() {
  local registrar=""
  local created=""
  local updated=""
  local expires=""
  local status_values=""
  local nameservers=""
  local rdap_name=""
  local rdap_handle=""
  local rdap_country=""
  local rdap_status_values=""
  local rdap_nameservers=""
  local rdap_events=""
  local ip_name=""
  local ip_org=""
  local ip_country=""
  local abuse_email=""

  registrar="$(whois_field_first '^(Registrar|Sponsoring Registrar|registrar):')"
  created="$(whois_field_first '^(Creation Date|Created On|Created|Registered):')"
  updated="$(whois_field_first '^(Updated Date|Last Updated|Changed):')"
  expires="$(whois_field_first '^(Registry Expiry Date|Expiration Date|Expiry Date|Expires On|paid-till|expire):')"
  status_values="$(whois_field_all_unique '^(Domain Status|Status|state):')"
  nameservers="$(whois_field_all_unique '^(Name Server|Nameserver|nserver):')"

  ip_name="$(whois_field_first '^(NetName|netname|Network Name):')"
  ip_org="$(whois_field_first '^(OrgName|org-name|descr|owner):')"
  ip_country="$(whois_field_first '^(Country|country):')"
  abuse_email="$(whois_field_first '^(OrgAbuseEmail|abuse-mailbox|abuse-c|Email):')"

  rdap_name="$(rdap_jq_first '.ldhName // .unicodeName // .name')"
  rdap_handle="$(rdap_jq_first '.handle')"
  rdap_country="$(rdap_jq_first '.country')"
  rdap_status_values="$(rdap_jq_all_unique '.status[]?')"
  rdap_nameservers="$(rdap_jq_all_unique '.nameservers[]?.ldhName')"
  rdap_events="$(
    if [[ -n "$RDAP_JSON" && "$RDAP_STATUS" == "collected" ]]; then
      jq -r '.events[]? | "\(.eventAction): \(.eventDate)"' <<< "$RDAP_JSON" 2>/dev/null | sort -u
    fi
  )"

  printf '%s\n' "${C_BOLD}Target${C_RESET}"
  printf '%s\n' "======"
  printf '  Input:          %s\n' "$TARGET"
  printf '  Normalized:     %s\n' "$NORMALIZED_TARGET"
  printf '  Type:           %s\n' "$TARGET_TYPE"

  if [[ "$TARGET_TYPE" == "domain" ]]; then
    printf '  Base domain:    %s\n' "$BASE_DOMAIN"
  fi

  printf '\n'
  printf '%s\n' "${C_BOLD}Collection${C_RESET}"
  printf '%s\n' "=========="
  printf '  WHOIS:          %s\n' "$WHOIS_STATUS"
  printf '  RDAP:           %s\n' "$RDAP_STATUS"

  if [[ -n "$RDAP_ERROR" ]]; then
    printf '  RDAP error:     %s\n' "$RDAP_ERROR"
  fi

  if [[ "$SAVE_OUTPUT" -eq 1 ]]; then
    printf '  Output dir:     %s\n' "$OUTPUT_DIR"
  fi

  if [[ "$TARGET_TYPE" == "domain" ]]; then
    printf '\n'
    printf '%s\n' "${C_BOLD}WHOIS Highlights${C_RESET}"
    printf '%s\n' "================"

    [[ -n "$registrar" ]] && printf '  Registrar:      %s\n' "$registrar"
    [[ -n "$created" ]] && printf '  Created:        %s\n' "$created"
    [[ -n "$updated" ]] && printf '  Updated:        %s\n' "$updated"
    [[ -n "$expires" ]] && printf '  Expires:        %s\n' "$expires"

    if [[ -n "$status_values" ]]; then
      printf '  Status:\n'
      sed 's/^/    - /' <<< "$status_values"
    fi

    if [[ -n "$nameservers" ]]; then
      printf '  Name servers:\n'
      sed 's/^/    - /' <<< "$nameservers"
    fi

    printf '\n'
    printf '%s\n' "${C_BOLD}RDAP Highlights${C_RESET}"
    printf '%s\n' "==============="

    [[ -n "$rdap_name" ]] && printf '  Name:           %s\n' "$rdap_name"
    [[ -n "$rdap_handle" ]] && printf '  Handle:         %s\n' "$rdap_handle"
    [[ -n "$rdap_country" ]] && printf '  Country:        %s\n' "$rdap_country"

    if [[ -n "$rdap_status_values" ]]; then
      printf '  Status:\n'
      sed 's/^/    - /' <<< "$rdap_status_values"
    fi

    if [[ -n "$rdap_nameservers" ]]; then
      printf '  Name servers:\n'
      sed 's/^/    - /' <<< "$rdap_nameservers"
    fi

    if [[ -n "$rdap_events" ]]; then
      printf '  Events:\n'
      sed 's/^/    - /' <<< "$rdap_events"
    fi
  else
    printf '\n'
    printf '%s\n' "${C_BOLD}WHOIS Highlights${C_RESET}"
    printf '%s\n' "================"

    [[ -n "$ip_name" ]] && printf '  Network name:   %s\n' "$ip_name"
    [[ -n "$ip_org" ]] && printf '  Organization:   %s\n' "$ip_org"
    [[ -n "$ip_country" ]] && printf '  Country:        %s\n' "$ip_country"
    [[ -n "$abuse_email" ]] && printf '  Abuse email:    %s\n' "$abuse_email"

    printf '\n'
    printf '%s\n' "${C_BOLD}RDAP Highlights${C_RESET}"
    printf '%s\n' "==============="

    [[ -n "$rdap_name" ]] && printf '  Name:           %s\n' "$rdap_name"
    [[ -n "$rdap_handle" ]] && printf '  Handle:         %s\n' "$rdap_handle"
    [[ -n "$rdap_country" ]] && printf '  Country:        %s\n' "$rdap_country"

    if [[ -n "$rdap_status_values" ]]; then
      printf '  Status:\n'
      sed 's/^/    - /' <<< "$rdap_status_values"
    fi

    if [[ -n "$rdap_events" ]]; then
      printf '  Events:\n'
      sed 's/^/    - /' <<< "$rdap_events"
    fi
  fi

  if [[ "$NO_HINTS" -eq 0 ]]; then
    printf '\n'
    printf '%s\n' "${C_BOLD}Hints${C_RESET}"
    printf '%s\n' "====="
    printf '  - WHOIS and RDAP may differ; compare both before making decisions.\n'
    printf '  - Use --save to preserve raw evidence for notes or escalation.\n'
    printf '  - This tool does not perform passive DNS, reputation, CT-log, or web-content analysis.\n'
  fi

  if [[ "$RAW_OUTPUT" -eq 1 ]]; then
    print_raw_text
  fi
}

print_raw_text() {
  printf '\n'
  printf '%s\n' "${C_BOLD}Raw WHOIS${C_RESET}"
  printf '%s\n' "========="
  if [[ -n "$WHOIS_TEXT" ]]; then
    printf '%s\n' "$WHOIS_TEXT"
  else
    printf '%s\n' "(none)"
  fi

  printf '\n'
  printf '%s\n' "${C_BOLD}Raw RDAP${C_RESET}"
  printf '%s\n' "========"
  if [[ -n "$RDAP_JSON" ]]; then
    jq . <<< "$RDAP_JSON" 2>/dev/null || printf '%s\n' "$RDAP_JSON"
  else
    printf '%s\n' "(none)"
  fi
}

print_json_summary() {
  local whois_json
  local rdap_json
  local whois_files_json
  local rdap_file_json

  whois_json="$(jq -Rn --arg text "$WHOIS_TEXT" '$text')"

  if [[ -n "$RDAP_JSON" && "$RDAP_STATUS" == "collected" ]]; then
    rdap_json="$(jq . <<< "$RDAP_JSON")"
  elif [[ -n "$RDAP_JSON" ]]; then
    rdap_json="$(jq -Rn --arg text "$RDAP_JSON" '$text')"
  else
    rdap_json="null"
  fi

  whois_files_json="$(
    if [[ "${#WHOIS_FILES[@]}" -gt 0 ]]; then
      printf '%s\n' "${WHOIS_FILES[@]}" | jq -R . | jq -s .
    else
      printf '[]'
    fi
  )"

  if [[ -n "$RDAP_FILE" ]]; then
    rdap_file_json="$(jq -Rn --arg path "$RDAP_FILE" '$path')"
  else
    rdap_file_json="null"
  fi

  jq -n \
    --arg input "$TARGET" \
    --arg normalized "$NORMALIZED_TARGET" \
    --arg targetType "$TARGET_TYPE" \
    --arg baseDomain "$BASE_DOMAIN" \
    --arg whoisStatus "$WHOIS_STATUS" \
    --arg rdapStatus "$RDAP_STATUS" \
    --arg rdapError "$RDAP_ERROR" \
    --arg outputDir "$OUTPUT_DIR" \
    --argjson whoisRaw "$whois_json" \
    --argjson rdap "$rdap_json" \
    --argjson whoisFiles "$whois_files_json" \
    --argjson rdapFile "$rdap_file_json" \
    '{
      target: {
        input: $input,
        normalized: $normalized,
        type: $targetType,
        baseDomain: (if $baseDomain == "" then null else $baseDomain end)
      },
      collection: {
        whois: $whoisStatus,
        rdap: $rdapStatus,
        rdapError: (if $rdapError == "" then null else $rdapError end),
        outputDir: (if $outputDir == "" then null else $outputDir end),
        whoisFiles: $whoisFiles,
        rdapFile: $rdapFile
      },
      data: {
        whoisRaw: $whoisRaw,
        rdap: $rdap
      }
    }'
}

print_output() {
  if [[ "$FORMAT" == "json" ]]; then
    print_json_summary
  else
    print_text_summary
  fi
}

main() {
  parse_args "$@"
  init_colors
  check_requirements
  normalize_target
  detect_base_domain
  prepare_output_dir

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry-run mode enabled."
  fi

  collect_whois
  collect_rdap
  print_output
}

main "$@"