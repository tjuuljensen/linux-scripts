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
#   bash, whois, curl, jq, ipcalc, grep, awk, sed, sort, date
#
# Version:
#   1.5.0
#
# Date:
#   2026-11-09
#
# Notes:
#   - RDAP is queried through the configured RDAP bootstrap/base service.
#   - WHOIS and RDAP can disagree. Treat both as evidence, not absolute truth.
#   - Stop/station/domain IDs and registration records can change over time.
#

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.5.0"

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
WHOIS_ERROR=""
WHOIS_SUCCESS_COUNT=0
WHOIS_FAILURE_COUNT=0
WHOIS_LAST_TEXT=""
WHOIS_LAST_SUCCESS=0
WHOIS_REFERRAL_COUNT=0
WHOIS_KRNIC_COLLECTED=0
WHOIS_JPNIC_COLLECTED=0
declare -A WHOIS_QUERIED_SERVERS=()
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
      Print raw collected WHOIS/RDAP data after the normalized summary.

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
  - Default output is a normalized text summary.
  - --save writes raw evidence files but still prints the normalized summary.
  - IP network type comes from the most specific matching WHOIS range.
    RDAP registry type is shown separately.
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
  require_command ipcalc
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
  local raw authority host port label rest

  command_exists ipcalc || die "Required command not found: ipcalc"
  raw="${TARGET#"${TARGET%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  [[ -n "$raw" ]] || { err "empty target"; exit 2; }

  if [[ "$raw" != *"://"* && "$raw" != \[* && "$raw" != */* ]] && ipcalc --check --silent "$raw"; then
    TARGET_TYPE="ip"
    NORMALIZED_TARGET="$(ipcalc --address --format=value "$raw")"
    verbose "Target type: $TARGET_TYPE"
    verbose "Normalized target: $NORMALIZED_TARGET"
    return 0
  fi

  if [[ "$raw" == *"://"* ]]; then
    authority="${raw#*://}"
    authority="${authority%%[/?#]*}"
  else
    authority="${raw%%[/?#]*}"
  fi
  authority="${authority##*@}"
  [[ -n "$authority" ]] || { err "could not extract target"; exit 2; }

  port=""
  if [[ "$authority" == \[* ]]; then
    if [[ "$authority" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
      host="${BASH_REMATCH[1]}"
      port="${BASH_REMATCH[3]:-}"
    else
      err "malformed IP address: $raw"
      exit 2
    fi
  elif [[ "$authority" == *:* ]]; then
    host="${authority%%:*}"
    port="${authority#*:}"
    if [[ "$port" == *:* || ! "$port" =~ ^[0-9]+$ ]]; then
      err "malformed IP address: $raw"
      exit 2
    fi
  else
    host="$authority"
  fi
  if [[ -n "$port" ]]; then
    while [[ "$port" == 0* && "$port" != 0 ]]; do port="${port#0}"; done
    if [[ "${#port}" -gt 5 ]] || (( 10#$port > 65535 )); then
      err "malformed IP address: $raw"
      exit 2
    fi
  fi

  host="${host,,}"
  if [[ "$host" != */* ]] && ipcalc --check --silent "$host"; then
    TARGET_TYPE="ip"
    NORMALIZED_TARGET="$(ipcalc --address --format=value "$host")"
  else
    if [[ "$host" =~ ^[0-9.]+$ || "$host" == *:* ]]; then
      err "malformed IP address: $raw"
      exit 2
    fi
    host="${host%.}"
    if [[ ! "$host" =~ ^[a-z0-9.-]+$ ]]; then
      err "unsupported target syntax: $raw"
      exit 2
    fi
    if [[ "$host" != *.* || "$host" == *..* ]]; then
      err "target does not look like a domain or IP: $raw"
      exit 2
    fi
    rest="$host"
    while [[ "$rest" == *.* ]]; do
      label="${rest%%.*}"
      [[ -n "$label" && "${#label}" -le 63 ]] || { err "invalid domain label in target: $raw"; exit 2; }
      rest="${rest#*.}"
    done
    [[ -n "$rest" && "${#rest}" -le 63 ]] || { err "invalid domain label in target: $raw"; exit 2; }
    TARGET_TYPE="domain"
    NORMALIZED_TARGET="$host"
  fi

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

  local suffix parent
  suffix="${NORMALIZED_TARGET#${NORMALIZED_TARGET%.*}.}"
  parent="${NORMALIZED_TARGET%.*}"
  BASE_DOMAIN="${parent##*.}.${suffix}"
  case "$BASE_DOMAIN" in
    co.uk|org.uk|ac.uk|gov.uk|com.au|net.au|org.au|co.nz|org.nz|com.br|com.mx|co.jp|ne.jp|or.jp|co.kr|or.kr|com.tr)
      if [[ "$parent" == *.* ]]; then
        parent="${parent%.*}"
        BASE_DOMAIN="${parent##*.}.${BASE_DOMAIN}"
      fi
      ;;
  esac

  if [[ "$BASE_DOMAIN" != "$NORMALIZED_TARGET" && "$NO_HINTS" -eq 0 && "$QUIET" -eq 0 ]]; then
    warn "Using heuristic base domain: $BASE_DOMAIN"
    warn "Use --base-domain if this is wrong."
  fi

  return 0
}

safe_filename() {
  local safe
  safe="$(printf '%s' "$1" | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^_+//; s/_+$//')"
  printf '%s\n' "${safe:-target}"
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

perform_whois_lookup() {
  local rc=0
  local label=""
  local detail=""

  printf -v label '%s ' "$@"
  label="${label% }"
  WHOIS_LAST_SUCCESS=0
  if WHOIS_LAST_TEXT="$(run_whois_command "$@")"; then
    rc=0
  else
    rc=$?
  fi

  if [[ "$rc" -eq 0 && -n "$WHOIS_LAST_TEXT" ]]; then
    WHOIS_LAST_SUCCESS=1
    WHOIS_SUCCESS_COUNT=$((WHOIS_SUCCESS_COUNT + 1))
    if [[ "$WHOIS_LAST_TEXT" == *"- KISA/KRNIC WHOIS Service -"* ]]; then
      WHOIS_KRNIC_COLLECTED=1
    fi
    if [[ "$WHOIS_LAST_TEXT" == *"JPNIC database provides information"* && "$WHOIS_LAST_TEXT" == *"[Network Number]"* ]]; then
      WHOIS_JPNIC_COLLECTED=1
    fi
  else
    WHOIS_FAILURE_COUNT=$((WHOIS_FAILURE_COUNT + 1))
    detail="${WHOIS_LAST_TEXT%%$'\n'*}"
    if [[ "$rc" -eq 0 ]]; then
      detail="empty response"
    fi
    if [[ -z "$WHOIS_ERROR" ]]; then
      WHOIS_ERROR="WHOIS query failed for ${label}: ${detail}"
    fi
    warn "WHOIS query failed for ${label}: ${detail}"
  fi
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

extract_whois_ip_referral_server() {
  local response="$1"
  local candidate=""

  candidate="$(
    printf '%s\n' "$response" |
      awk '
        BEGIN { jpnic_banner=0; jpnic_english=0; found=0 }
        {
          line = tolower($0)
          if (line ~ /jpnic database provides information/) jpnic_banner=1
          if (line ~ /\[network number\]/) jpnic_english=1
          if (line ~ /^[[:space:]]*(refer|whois|whois server|referralserver):[[:space:]]*/) {
            sub(/^[^:]+:[[:space:]]*/, "", $0)
            split($0, parts, /[[:space:]]+/)
            print parts[1]
            found=1
            exit
          }
          if (line ~ /^remarks:[[:space:]]*(krnic|twnic) whois server at[[:space:]]+/) {
            sub(/^.*[[:space:]]at[[:space:]]+/, "", $0)
            split($0, parts, /[[:space:]]+/)
            print parts[1]
            found=1
            exit
          }
          if (line ~ /^remarks:.*whois\.nic\.ad\.jp/) {
            print "whois.nic.ad.jp"
            found=1
            exit
          }
        }
        END {
          if (!found && jpnic_banner && !jpnic_english) print "whois.nic.ad.jp"
        }
      '
  )"

  [[ -n "$candidate" ]] || return 0

  candidate="${candidate,,}"
  candidate="${candidate#whois://}"
  candidate="${candidate%.}"
  candidate="${candidate%:43}"
  [[ "${#candidate}" -le 253 && "$candidate" =~ ^[a-z0-9.-]+$ && "$candidate" == *.* ]] || return 1
  case "$candidate" in
    *.local|*.internal|*.test|*.invalid|*.example) return 1 ;;
  esac
  if ipcalc --check --silent "$candidate"; then return 1; fi
  local label rest="$candidate"
  while [[ "$rest" == *.* ]]; do
    label="${rest%%.*}"
    [[ -n "$label" && "${#label}" -le 63 && "$label" != -* && "$label" != *- ]] || return 1
    rest="${rest#*.}"
  done
  [[ -n "$rest" && "${#rest}" -le 63 && "$rest" != -* && "$rest" != *- ]] || return 1
  printf '%s\n' "$candidate"
}

follow_whois_ip_referrals() {
  local ip="$1"
  local response="$2"
  local referral=""
  local depth=0
  local file=""

  while [[ "$depth" -lt "$MAX_REFERRALS" ]]; do
    referral="$(extract_whois_ip_referral_server "$response")" || {
      warn "Ignoring invalid WHOIS referral server."
      break
    }
    [[ -n "$referral" ]] || break

    if [[ -n "${WHOIS_QUERIED_SERVERS[$referral]:-}" ]]; then
      verbose "Skipping repeated WHOIS referral server: $referral"
      break
    fi
    if [[ "$WHOIS_KRNIC_COLLECTED" -eq 1 && ( "$referral" == "whois.kisa.or.kr" || "$referral" == "whois.nic.or.kr" ) ]]; then
      verbose "Skipping KRNIC referral; authoritative KRNIC data is already collected."
      break
    fi
    if [[ "$WHOIS_JPNIC_COLLECTED" -eq 1 && "$referral" == "whois.nic.ad.jp" ]]; then
      verbose "Skipping JPNIC referral; authoritative JPNIC data is already collected."
      break
    fi

    WHOIS_QUERIED_SERVERS["$referral"]=1
    depth=$((depth + 1))
    WHOIS_REFERRAL_COUNT=$((WHOIS_REFERRAL_COUNT + 1))
    log "Following IP WHOIS referral ${depth}/${MAX_REFERRALS}: $referral"

    if [[ "$referral" == "whois.nic.ad.jp" ]]; then
      perform_whois_lookup -h "$referral" "${ip}/e"
    else
      perform_whois_lookup -h "$referral" "$ip"
    fi
    if [[ "$WHOIS_LAST_SUCCESS" -eq 1 && "$WHOIS_LAST_TEXT" == "$response" ]]; then
      verbose "WHOIS referral returned the same record: $referral"
      break
    fi
    response="$WHOIS_LAST_TEXT"
    WHOIS_TEXT+=$'\n'
    WHOIS_TEXT+="===== WHOIS referral: ${referral} ====="
    WHOIS_TEXT+=$'\n'
    WHOIS_TEXT+="$response"
    WHOIS_TEXT+=$'\n'

    if [[ "$SAVE_OUTPUT" -eq 1 ]]; then
      file="${OUTPUT_DIR}/whois-ip-referral-${WHOIS_REFERRAL_COUNT}-$(safe_filename "$referral").txt"
      save_text_file "$file" "$response"
      WHOIS_FILES+=("$file")
    fi

    [[ "$WHOIS_LAST_SUCCESS" -eq 1 ]] || break
  done
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

  perform_whois_lookup "$current_query"
  text="$WHOIS_LAST_TEXT"
  combined+=$'===== WHOIS default =====\n'
  combined+="$text"
  combined+=$'\n'

  if [[ "$SAVE_OUTPUT" -eq 1 ]]; then
    file="${OUTPUT_DIR}/whois-default.txt"
    save_text_file "$file" "$text"
    WHOIS_FILES+=("$file")
  fi

  if [[ "$WHOIS_LAST_SUCCESS" -eq 1 ]]; then
    referral="$(extract_whois_referral_server "$text")"
  fi

  while [[ -n "$referral" && "$depth" -lt "$MAX_REFERRALS" ]]; do
    if grep -Fqx -- "$referral" <<< "$seen_servers"; then
      verbose "Skipping repeated WHOIS referral server: $referral"
      break
    fi

    seen_servers+="${referral}"$'\n'
    depth=$((depth + 1))

    log "Following WHOIS referral ${depth}/${MAX_REFERRALS}: $referral"

    perform_whois_lookup -h "$referral" "$query"
    text="$WHOIS_LAST_TEXT"

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

    referral=""
    if [[ "$WHOIS_LAST_SUCCESS" -eq 1 ]]; then
      referral="$(extract_whois_referral_server "$text")"
    fi
  done

  WHOIS_TEXT="$combined"
}

collect_whois_ip_default() {
  local ip="$1"
  local text=""
  local file=""

  log "Collecting WHOIS for IP: $ip"

  perform_whois_lookup "$ip"
  text="$WHOIS_LAST_TEXT"

  WHOIS_TEXT+=$'===== WHOIS default =====\n'
  WHOIS_TEXT+="$text"
  WHOIS_TEXT+=$'\n'

  if [[ "$SAVE_OUTPUT" -eq 1 ]]; then
    file="${OUTPUT_DIR}/whois-default.txt"
    save_text_file "$file" "$text"
    WHOIS_FILES+=("$file")
  fi

  if [[ "$WHOIS_LAST_SUCCESS" -eq 1 ]]; then
    follow_whois_ip_referrals "$ip" "$text"
  fi
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

    WHOIS_QUERIED_SERVERS["$rir"]=1
    perform_whois_lookup -h "$rir" "$ip"
    text="$WHOIS_LAST_TEXT"

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

    if [[ "$WHOIS_LAST_SUCCESS" -eq 1 ]]; then
      follow_whois_ip_referrals "$ip" "$text"
    fi
  done
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

  if [[ "$WHOIS_SUCCESS_COUNT" -eq 0 ]]; then
    WHOIS_STATUS="unavailable"
  elif [[ "$WHOIS_FAILURE_COUNT" -gt 0 ]]; then
    WHOIS_STATUS="partial"
  else
    WHOIS_STATUS="collected"
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
      tolower($0) ~ tolower(pat) {
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
      tolower($0) ~ tolower(pat) {
        sub(/^[^:]+:[[:space:]]*/, "", $0)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        if ($0 != "") print
      }
    ' |
    sort -u
}

whois_jpnic_field_all_unique() {
  local label="$1"

  printf '%s\n' "$WHOIS_TEXT" |
    awk -v label="$label" '
      /^[[:alpha:]]\.[[:space:]]*\[/ && index(tolower($0), "[" tolower(label) "]") {
        sub(/^[[:alpha:]]\.[[:space:]]*\[[^]]+\][[:space:]]*/, "", $0)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        if ($0 != "") print
      }
    ' |
    sort -u
}

whois_ip_selected_fields() {
  # Compare fixed-width hexadecimal addresses so IPv6 ranges do not depend on
  # the shell or awk having 128-bit integer arithmetic.
  awk -v target="$NORMALIZED_TARGET" '
    function v4hex(ip, octets, n, i, result) {
      n = split(ip, octets, /\./)
      if (n != 4) return ""
      result = ""
      for (i = 1; i <= 4; i++) {
        if (octets[i] !~ /^[0-9]+$/ || octets[i] + 0 > 255) return ""
        result = result sprintf("%02x", octets[i] + 0)
      }
      return result
    }
    function grouphex(group) {
      if (group !~ /^[0-9a-f]+$/ || length(group) < 1 || length(group) > 4) return ""
      return substr("0000" group, length(group) + 1)
    }
    function iphex(ip, parts, left, right, nleft, nright, missing, i, group, result, tail) {
      ip = tolower(ip)
      if (index(ip, ":") == 0) return v4hex(ip)
      if (index(ip, ".")) {
        nleft = split(ip, parts, ":")
        tail = v4hex(parts[nleft])
        if (tail == "") return ""
        sub(/[^:]+$/, substr(tail, 1, 4) ":" substr(tail, 5, 4), ip)
      }
      result = ""
      if (index(ip, "::")) {
        i = index(ip, "::")
        left = substr(ip, 1, i - 1)
        right = substr(ip, i + 2)
        nleft = left == "" ? 0 : split(left, parts, ":")
        for (i = 1; i <= nleft; i++) {
          group = grouphex(parts[i])
          if (group == "") return ""
          result = result group
        }
        nright = right == "" ? 0 : split(right, parts, ":")
        missing = 8 - nleft - nright
        if (missing < 1) return ""
        for (i = 1; i <= missing; i++) result = result "0000"
        for (i = 1; i <= nright; i++) {
          group = grouphex(parts[i])
          if (group == "") return ""
          result = result group
        }
      } else {
        if (split(ip, parts, ":") != 8) return ""
        for (i = 1; i <= 8; i++) {
          group = grouphex(parts[i])
          if (group == "") return ""
          result = result group
        }
      }
      return result
    }
    function nibble(char) { return index("0123456789abcdef", char) - 1 }
    function hexwidth(start, end, i, digit, borrow, result) {
      borrow = 0
      result = ""
      for (i = length(start); i >= 1; i--) {
        digit = nibble(substr(end, i, 1)) - nibble(substr(start, i, 1)) - borrow
        if (digit < 0) { digit += 16; borrow = 1 } else borrow = 0
        result = substr("0123456789abcdef", digit + 1, 1) result
      }
      return result
    }
    function range_bounds(raw, parts, count, prefix, base, total, i, keep, block, digit, low, high) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", raw)
      sub(/[[:space:]]*\([^)]+\).*$/, "", raw)
      BSTART = BEND = ""
      if (index(raw, "-")) {
        count = split(raw, parts, /[[:space:]]*-[[:space:]]*/)
        if (count != 2) return 0
        BSTART = iphex(parts[1])
        BEND = iphex(parts[2])
      } else if (index(raw, "/")) {
        count = split(raw, parts, "/")
        if (count != 2 || parts[2] !~ /^[0-9]+$/) return 0
        base = iphex(parts[1])
        total = length(base) * 4
        prefix = parts[2] + 0
        if (base == "" || prefix > total) return 0
        for (i = 1; i <= length(base); i++) {
          digit = nibble(substr(base, i, 1))
          keep = prefix - (i - 1) * 4
          if (keep >= 4) { low = high = digit }
          else if (keep <= 0) { low = 0; high = 15 }
          else {
            block = 2 ^ (4 - keep)
            low = int(digit / block) * block
            high = low + block - 1
          }
          BSTART = BSTART substr("0123456789abcdef", low + 1, 1)
          BEND = BEND substr("0123456789abcdef", high + 1, 1)
        }
      } else BSTART = BEND = iphex(raw)
      return BSTART != "" && length(BSTART) == length(BEND) && ("x" BSTART <= "x" BEND)
    }
    function clear_current() {
      current_match = current_rpsl = 0
      current_name = current_org = current_descr = current_status = current_note = current_type = ""
    }
    function commit( org) {
      if (!current_match) { clear_current(); return }
      if (current_rpsl && (best_rpsl_width == "" || ("x" current_width <= "x" best_rpsl_width))) {
        if (best_rpsl_width == "" || ("x" current_width < "x" best_rpsl_width))
          best_name = best_org = best_status = best_note = ""
        best_rpsl_width = current_width
        org = current_org != "" ? current_org : current_descr
        if (current_name != "") best_name = current_name
        if (org != "") best_org = org
        if (current_status != "") best_status = current_status
        if (current_note != "") best_note = current_note
      }
      if (best_type_width == "" || ("x" current_width < "x" best_type_width)) {
        delete types
        best_type_width = current_width
      }
      if (current_width == best_type_width && current_type != "") types[current_type] = 1
      clear_current()
    }
    BEGIN { targethex = iphex(target); clear_current() }
    /^===== WHOIS/ { commit(); next }
    /^[[:space:]]*$/ { if (current_rpsl) commit(); next }
    {
      colon = index($0, ":")
      if (!colon) next
      key = tolower(substr($0, 1, colon - 1))
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      value = substr($0, colon + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/[[:cntrl:]]/, " ", value)
      if (key ~ /^(ipv[46] address|netrange|inetnum|inet6num)$/) {
        commit()
        if (range_bounds(value) && length(BSTART) == length(targethex) &&
            ("x" BSTART <= "x" targethex) && ("x" targethex <= "x" BEND)) {
          current_match = 1
          current_rpsl = key ~ /^(inetnum|inet6num)$/
          current_width = hexwidth(BSTART, BEND)
        }
        next
      }
      if (!current_match) next
      if (key == "network type") current_type = value
      if (!current_rpsl) next
      if (key == "netname") current_name = value
      else if ((key == "org-name" || key == "orgname" || key == "owner") && current_org == "") current_org = value
      else if (key == "descr" && current_descr == "") current_descr = value
      else if (key == "status" && current_status == "") current_status = value
      else if (key == "remarks" && current_note == "" && length(value) <= 120 &&
               tolower(value) !~ /whois|mirrored|more specific information/ &&
               value !~ /^\([^)]*\)$/) current_note = value
    }
    END {
      commit()
      if (best_name != "") print "name\t" best_name
      if (best_org != "") print "organization\t" best_org
      if (best_status != "") print "status\t" best_status
      if (best_note != "") print "note\t" best_note
      for (kind in types) print "type\t" kind
    }
  ' <<< "$WHOIS_TEXT"
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
  local ip_org_values=""
  local ip_networks=""
  local ip_network_types=""
  local ip_rpsl_name=""
  local ip_rpsl_org=""
  local ip_rpsl_status=""
  local ip_rpsl_note=""
  local ip_field=""
  local ip_value=""
  local ip_country=""
  local abuse_email=""
  local contact_email=""
  local rdap_network=""
  local rdap_type=""
  local rdap_description=""
  local rdap_contacts=""

  registrar="$(whois_field_first '^(Registrar|Sponsoring Registrar|registrar):')"
  created="$(whois_field_first '^(Creation Date|Created On|Created|Registered):')"
  updated="$(whois_field_first '^(Updated Date|Last Updated|Changed):')"
  expires="$(whois_field_first '^(Registry Expiry Date|Expiration Date|Expiry Date|Expires On|paid-till|expire):')"
  status_values="$(whois_field_all_unique '^(Domain Status|Status|state):')"
  nameservers="$(whois_field_all_unique '^(Name Server|Nameserver|nserver):')"

  if [[ "$TARGET_TYPE" == "ip" && "$WHOIS_SUCCESS_COUNT" -gt 0 ]]; then
    while IFS=$'\t' read -r ip_field ip_value; do
      case "$ip_field" in
        name) ip_rpsl_name="$ip_value" ;;
        organization) ip_rpsl_org="$ip_value" ;;
        status) ip_rpsl_status="$ip_value" ;;
        note) ip_rpsl_note="$ip_value" ;;
        type) ip_network_types+="${ip_value}"$'\n' ;;
      esac
    done < <(whois_ip_selected_fields)
    if [[ -n "$ip_network_types" ]]; then
      ip_network_types="$(sort -u <<< "$ip_network_types" | sed '/^$/d')"
    fi
  fi

  ip_name="$(whois_jpnic_field_all_unique 'Network Name' | awk 'NR == 1 { print }')"
  if [[ "$TARGET_TYPE" == "ip" && -z "$ip_name" ]]; then
    ip_name="$ip_rpsl_name"
  fi
  if [[ -z "$ip_name" ]]; then
    ip_name="$(whois_field_first '^(Service Name|NetName|Network Name)[[:space:]]*:')"
  fi
  ip_org_values="$(whois_jpnic_field_all_unique 'Organization')"
  if [[ -z "$ip_org_values" ]]; then
    ip_org_values="$(whois_field_all_unique '^Organization Name[[:space:]]*:')"
  fi
  if [[ "$TARGET_TYPE" == "ip" && -z "$ip_org_values" ]]; then
    ip_org_values="$ip_rpsl_org"
  fi
  if [[ -z "$ip_org_values" ]]; then
    ip_org_values="$(whois_field_all_unique '^(OrgName|org-name|descr|owner)[[:space:]]*:')"
  fi
  ip_networks="$(whois_jpnic_field_all_unique 'Network Number')"
  if [[ -z "$ip_networks" ]]; then
    ip_networks="$(whois_field_all_unique '^IPv[46] Address[[:space:]]*:')"
  fi
  if [[ -z "$ip_networks" ]]; then
    ip_networks="$(whois_field_all_unique '^(NetRange|inetnum|inet6num|CIDR)[[:space:]]*:')"
  fi
  ip_country="$(whois_field_first '^(Country|country):')"
  abuse_email="$(whois_field_first '^(OrgAbuseEmail|abuse-mailbox)[[:space:]]*:')"
  contact_email="$(whois_field_first '^(E-Mail|OrgTechEmail|OrgNOCEmail)[[:space:]]*:')"

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
  if [[ "$TARGET_TYPE" == "ip" && "$RDAP_STATUS" == "collected" ]]; then
    rdap_network="$(rdap_jq_first 'if .startAddress and .endAddress then "\(.startAddress) - \(.endAddress)" else empty end')"
    rdap_type="$(rdap_jq_first '.type')"
    rdap_description="$(rdap_jq_first '.remarks[]? | select(.title == "description") | .description[]?')"
    rdap_contacts="$(
      jq -r '
        def values($e; $field):
          [($e.vcardArray[1] // [])[]? | select(.[0] == $field) | .[3] | select(type == "string")] | unique;
        .entities[]? as $e
        | ($e.roles // ["contact"])[] as $role
        | (values($e; "fn")[0] // $e.handle // "unknown") as $name
        | (values($e; "email") | join(", ")) as $email
        | (values($e; "tel") | join(", ")) as $phone
        | "\($role): \($name)\(if $email == "" then "" else " <\($email)>" end)\(if $phone == "" then "" else " (\($phone))" end)"
      ' <<< "$RDAP_JSON" 2>/dev/null | sort -u | awk 'NR <= 6 { print }'
    )"
  fi

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

  if [[ -n "$WHOIS_ERROR" ]]; then
    printf '  WHOIS error:    %s\n' "$WHOIS_ERROR"
  fi

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
    if [[ -n "$ip_networks" ]]; then
      printf '  Network ranges:\n'
      sed 's/^/    - /' <<< "$ip_networks"
    fi
    if [[ -n "$ip_network_types" ]]; then
      if [[ "$ip_network_types" == *$'\n'* ]]; then
        printf '  Network types (conflicting):\n'
        sed 's/^/    - /' <<< "$ip_network_types"
      else
        printf '  Network type:   %s\n' "$ip_network_types"
      fi
    fi
    [[ -n "$ip_rpsl_status" ]] && printf '  WHOIS status:   %s\n' "$ip_rpsl_status"
    [[ -n "$ip_rpsl_note" ]] && printf '  Network note:   %s\n' "$ip_rpsl_note"
    if [[ -n "$ip_org_values" ]]; then
      printf '  Organizations:\n'
      sed 's/^/    - /' <<< "$ip_org_values"
    fi
    [[ -n "$ip_country" ]] && printf '  Country:        %s\n' "$ip_country"
    [[ -n "$abuse_email" ]] && printf '  Abuse email:    %s\n' "$abuse_email"
    [[ -n "$contact_email" ]] && printf '  Contact email:  %s\n' "$contact_email"

    printf '\n'
    printf '%s\n' "${C_BOLD}RDAP Highlights${C_RESET}"
    printf '%s\n' "==============="

    [[ -n "$rdap_name" ]] && printf '  Name:           %s\n' "$rdap_name"
    [[ -n "$rdap_handle" && "$rdap_handle" != "$rdap_network" ]] && printf '  Handle:         %s\n' "$rdap_handle"
    [[ -n "$rdap_network" ]] && printf '  Network range:  %s\n' "$rdap_network"
    [[ -n "$rdap_type" ]] && printf '  Registry type:  %s\n' "$rdap_type"
    [[ -n "$rdap_description" ]] && printf '  Description:    %s\n' "$rdap_description"
    [[ -n "$rdap_country" ]] && printf '  Country:        %s\n' "$rdap_country"

    if [[ -n "$rdap_contacts" ]]; then
      printf '  Contacts:\n'
      sed 's/^/    - /' <<< "$rdap_contacts"
    fi

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
    printf '  - Use --raw for full records, or --save to preserve raw evidence.\n'
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
    --arg whoisError "$WHOIS_ERROR" \
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
        whoisError: (if $whoisError == "" then null else $whoisError end),
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
  normalize_target
  check_requirements
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
