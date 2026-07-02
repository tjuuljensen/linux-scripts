#!/usr/bin/env bash
#
# urlxray.sh
#
# Purpose:
#   Inspect a URL and show its HTTP redirect chain and final effective URL.
#
# Description:
#   Useful for expanding short URLs, checking tracking links, and inspecting
#   where a URL redirects before opening it in a browser.
#
# Safety / privacy:
#   Normal mode contacts the supplied URL and redirect targets.
#   Safe/paranoia mode performs local-only URL inspection and does not contact
#   the origin, perform DNS lookups, or follow redirects.
#
# Default behavior:
#   Uses HTTP HEAD requests to avoid downloading the response body. Some sites
#   handle HEAD differently from GET; use --get if HEAD does not work.
#
# Requirements:
#   Normal mode: bash, curl, awk, sed, grep
#   Safe mode:   bash, python3
#
# Author:
#   Torsten Juul-Jensen
#
# Version:
#   1.1.1
#
# Date:
#   2026-07-02

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.1.1"

URL=""
METHOD="HEAD"
QUIET=0
SHOW_HEADERS=0
SAFE_MODE=0
MAX_REDIRS=10
MAX_TIME=20
CONNECT_TIMEOUT=5
USER_AGENT="urlxray/${SCRIPT_VERSION}"

TMP_FILES=()

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

cleanup() {
  if [[ "${#TMP_FILES[@]}" -gt 0 ]]; then
    rm -f -- "${TMP_FILES[@]}"
  fi
}

trap cleanup EXIT

usage() {
  cat <<USAGE
${SCRIPT_NAME} ${SCRIPT_VERSION}

Inspect a URL redirect chain.

Usage:
  ${SCRIPT_NAME} [options] URL

Options:
  --safe, --paranoia
      Local-only inspection mode.
      Does not contact the origin, does not follow redirects, and does not do
      DNS lookups.

      This cannot reveal live server-side redirect targets unless they are
      already embedded in the URL.

  --get
      Use GET instead of HEAD.
      This can work better on sites that do not support HEAD correctly, but it
      may download response content.

  --head
      Use HEAD requests.
      This is the default.

  -q, --quiet
      Normal mode: print only the final effective URL.
      Safe mode: print only the original URL.

  --headers
      Print response headers captured during the request.
      Ignored in --safe mode.

  --max-redirs N
      Maximum number of redirects to follow.
      Default: 10

  --max-time SECONDS
      Maximum total request time.
      Default: 20

  --connect-timeout SECONDS
      Maximum connection setup time.
      Default: 5

  --user-agent STRING
      User-Agent header to send.
      Default: ${USER_AGENT}

  -h, --help
      Show this help.

  --version
      Show version information.

Examples:
  ${SCRIPT_NAME} https://bit.ly/example

  ${SCRIPT_NAME} --quiet https://bit.ly/example

  ${SCRIPT_NAME} --get https://example.com

  ${SCRIPT_NAME} --headers https://example.com

  ${SCRIPT_NAME} --safe https://bit.ly/example

  ${SCRIPT_NAME} --paranoia "https://example.com/redirect?url=https%3A%2F%2Fevil.example%2Flogin"

Limitations:
  Normal mode does not execute JavaScript.
  Normal mode does not follow HTML meta refresh redirects.
  Safe mode does not contact the origin and therefore cannot resolve live
  server-side redirects.

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
      --safe|--paranoia)
        SAFE_MODE=1
        shift
        ;;
      --get)
        METHOD="GET"
        shift
        ;;
      --head)
        METHOD="HEAD"
        shift
        ;;
      -q|--quiet)
        QUIET=1
        shift
        ;;
      --headers)
        SHOW_HEADERS=1
        shift
        ;;
      --max-redirs)
        MAX_REDIRS="${2:-}"
        shift 2
        ;;
      --max-time)
        MAX_TIME="${2:-}"
        shift 2
        ;;
      --connect-timeout)
        CONNECT_TIMEOUT="${2:-}"
        shift 2
        ;;
      --user-agent)
        USER_AGENT="${2:-}"
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
        err "Unknown option: $1"
        usage >&2
        exit 2
        ;;
      *)
        if [[ -n "$URL" ]]; then
          die "Only one URL may be specified."
        fi
        URL="$1"
        shift
        ;;
    esac
  done

  [[ -n "$URL" ]] || {
    usage >&2
    exit 2
  }

  [[ "$MAX_REDIRS" =~ ^[0-9]+$ ]] || die "--max-redirs must be a non-negative integer."
  [[ "$MAX_TIME" =~ ^[0-9]+$ ]] || die "--max-time must be a positive integer."
  [[ "$CONNECT_TIMEOUT" =~ ^[0-9]+$ ]] || die "--connect-timeout must be a positive integer."
}

validate_url() {
  case "$URL" in
    http://*|https://*)
      ;;
    *)
      die "URL must start with http:// or https://"
      ;;
  esac
}

check_requirements() {
  local cmd

  if [[ "$SAFE_MODE" -eq 1 ]]; then
    command_exists python3 || die "Required command not found for --safe mode: python3"
    return 0
  fi

  for cmd in curl awk sed grep; do
    command_exists "$cmd" || die "Required command not found: $cmd"
  done
}

safe_inspect_url() {
  python3 - "$URL" "$QUIET" <<'PY'
import ipaddress
import sys
from urllib.parse import urlsplit, unquote, parse_qsl

url = sys.argv[1]
quiet = sys.argv[2] == "1"

known_shorteners = {
    "bit.ly", "bitly.com", "t.co", "tinyurl.com", "goo.gl", "ow.ly",
    "is.gd", "buff.ly", "cutt.ly", "rebrand.ly", "lnkd.in",
    "youtu.be", "shorturl.at", "tiny.cc", "trib.al", "ift.tt",
}

redirect_params = {
    "url", "u", "uri", "redirect", "redirect_url", "target", "target_url",
    "dest", "destination", "continue", "next", "to", "r", "link", "q",
}

tracking_params = {
    "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
    "fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid",
}

def idna_decode(host: str) -> str:
    try:
        return host.encode("ascii").decode("idna")
    except Exception:
        return host

def is_probably_url(value: str) -> bool:
    lowered = value.lower()
    return lowered.startswith("http://") or lowered.startswith("https://")

try:
    parts = urlsplit(url)
except Exception as exc:
    print(f"ERROR: Could not parse URL: {exc}", file=sys.stderr)
    raise SystemExit(2)

if not parts.scheme or not parts.netloc:
    print("ERROR: URL must include scheme and host, for example https://example.com", file=sys.stderr)
    raise SystemExit(2)

try:
    host = parts.hostname or ""
    port = parts.port
except ValueError as exc:
    print(f"ERROR: Invalid URL port: {exc}", file=sys.stderr)
    raise SystemExit(2)

scheme = parts.scheme.lower()
host_lower = host.lower()
display_host = idna_decode(host_lower)
decoded_path = unquote(parts.path)
decoded_query = unquote(parts.query)
query_pairs = parse_qsl(parts.query, keep_blank_values=True)

embedded_targets = []
tracking_found = []

for key, value in query_pairs:
    key_lower = key.lower()

    if key_lower in redirect_params and is_probably_url(value):
        embedded_targets.append((key, value))

    if key_lower in tracking_params:
        tracking_found.append(key)

if quiet:
    print(url)
    raise SystemExit(0)

print("Safe URL inspection")
print("-------------------")
print("Network access:    none")
print("Origin contacted:  no")
print()
print(f"Original URL:      {url}")
print(f"Scheme:            {scheme}")
print(f"Host:              {host_lower}")

if display_host != host_lower:
    print(f"Display host:      {display_host}")

if port is not None:
    print(f"Port:              {port}")

print(f"Path:              {parts.path or '/'}")

if decoded_path != parts.path:
    print(f"Decoded path:      {decoded_path}")

if parts.query:
    print(f"Query:             {parts.query}")
    if decoded_query != parts.query:
        print(f"Decoded query:     {decoded_query}")

if parts.fragment:
    print(f"Fragment:          {parts.fragment}")

print()

warnings = []

if scheme not in {"http", "https"}:
    warnings.append(f"Unexpected URL scheme: {scheme}")

if scheme == "http":
    warnings.append("Plain HTTP URL, not HTTPS.")

if parts.username or parts.password:
    warnings.append("URL contains username/password-style userinfo before @. This can hide the real host.")

if host_lower in known_shorteners:
    warnings.append("Known shortener domain. Live destination cannot be known without contacting it.")

if any(host_lower.endswith("." + domain) for domain in known_shorteners):
    warnings.append("Subdomain of a known shortener domain.")

if host_lower != display_host:
    warnings.append("Hostname uses punycode/IDN. Check the display host carefully.")

if "\\" in url:
    warnings.append("URL contains backslash characters, which can be interpreted inconsistently.")

if "@" in parts.path:
    warnings.append("Path contains @. Check for visual deception.")

if "%" in parts.path or "%" in parts.query:
    warnings.append("URL contains percent-encoding. Review decoded path/query.")

try:
    ip = ipaddress.ip_address(host_lower.strip("[]"))
    warnings.append(f"Host is an IP address: {ip}")

    if ip.is_private:
        warnings.append("IP address is private/internal.")
    if ip.is_loopback:
        warnings.append("IP address is loopback/localhost.")
    if ip.is_link_local:
        warnings.append("IP address is link-local.")
    if ip.is_multicast:
        warnings.append("IP address is multicast.")
    if ip.is_reserved:
        warnings.append("IP address is reserved.")
    if ip.is_unspecified:
        warnings.append("IP address is unspecified.")
except ValueError:
    pass

if embedded_targets:
    print("Embedded redirect-like parameters:")
    for key, value in embedded_targets:
        print(f"  {key}= {value}")
    print()

if tracking_found:
    print("Tracking parameters found:")
    for key in sorted(set(tracking_found)):
        print(f"  {key}")
    print()

print("Warnings:")
if warnings:
    for warning in warnings:
        print(f"  WARN: {warning}")
else:
    print("  None from local inspection.")

print()
print("Limitation:")
print("  This mode cannot expand server-side redirects because it intentionally")
print("  does not contact the origin server.")
PY
}

curl_common_args() {
  printf '%s\0' \
    --silent \
    --show-error \
    --location \
    --max-redirs "$MAX_REDIRS" \
    --max-time "$MAX_TIME" \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --user-agent "$USER_AGENT" \
    --proto '=http,https' \
    --proto-redir '=http,https'
}

fetch_headers_and_effective_url() {
  local header_file="$1"
  local effective_file="$2"
  local curl_args=()

  while IFS= read -r -d '' arg; do
    curl_args+=("$arg")
  done < <(curl_common_args)

  if [[ "$METHOD" == "HEAD" ]]; then
    curl_args+=(--head --output /dev/null)
  else
    curl_args+=(--output /dev/null)
  fi

  curl \
    "${curl_args[@]}" \
    --dump-header "$header_file" \
    --write-out '%{url_effective}\n%{http_code}\n%{num_redirects}\n' \
    "$URL" \
    > "$effective_file"
}

print_redirect_chain() {
  local header_file="$1"

  awk '
    BEGIN {
      response = 0
    }

    /^HTTP\// {
      response++
      status[response] = $0
    }

    /^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*/ {
      line = $0
      sub(/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*/, "", line)
      sub(/\r$/, "", line)
      location[response] = line
    }

    END {
      for (i = 1; i <= response; i++) {
        if (status[i] != "") {
          printf "%02d  %s\n", i, status[i]
        }
        if (location[i] != "") {
          printf "    -> %s\n", location[i]
        }
      }
    }
  ' "$header_file"
}

print_headers() {
  local header_file="$1"

  sed 's/\r$//' "$header_file"
}

main() {
  parse_args "$@"
  check_requirements
  validate_url

  if [[ "$SAFE_MODE" -eq 1 ]]; then
    safe_inspect_url
    exit 0
  fi

  local header_file
  local effective_file
  local final_url
  local http_code
  local num_redirects

  header_file="$(mktemp)"
  effective_file="$(mktemp)"
  TMP_FILES+=("$header_file" "$effective_file")

  if ! fetch_headers_and_effective_url "$header_file" "$effective_file"; then
    err "curl request failed."
    exit 1
  fi

  final_url="$(sed -n '1p' "$effective_file")"
  http_code="$(sed -n '2p' "$effective_file")"
  num_redirects="$(sed -n '3p' "$effective_file")"

  if [[ "$QUIET" -eq 1 ]]; then
    [[ -n "$final_url" ]] || exit 2
    printf '%s\n' "$final_url"
    exit 0
  fi

  printf 'Input URL:       %s\n' "$URL"
  printf 'Method:          %s\n' "$METHOD"
  printf 'Redirects:       %s\n' "${num_redirects:-0}"
  printf 'Final HTTP code: %s\n' "${http_code:-unknown}"
  printf 'Final URL:       %s\n' "${final_url:-unknown}"
  printf '\n'

  printf 'Redirect chain:\n'
  print_redirect_chain "$header_file"

  if [[ "$SHOW_HEADERS" -eq 1 ]]; then
    printf '\nHeaders:\n'
    print_headers "$header_file"
  fi
}

main "$@"