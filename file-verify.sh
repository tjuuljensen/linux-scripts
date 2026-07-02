#!/usr/bin/env bash
#
# file-verify.sh
#
# Purpose:
#   Verify a downloaded file using detached OpenPGP/GPG signatures and/or
#   checksum files.
#
# Description:
#   This script verifies release artifacts such as .tar.gz, .zip, .iso, and
#   similar files. It supports detached GPG signatures and SHA256/SHA512
#   checksum files. MD5 and SHA1 checks are intentionally disabled by default
#   because they are legacy algorithms and should not be treated as modern
#   security verification.
#
# Security model:
#   - A GPG signature is useful only if the signing key is trusted or its full
#     fingerprint has been independently verified.
#   - A checksum file is useful only if the checksum came from a trusted source.
#   - Downloading a key from a keyserver based only on the signature's key ID
#     does not prove vendor authenticity.
#
# Supported signature files:
#   FILE.sig
#   FILE.asc
#
# Supported checksum files:
#   FILE.sha256
#   FILE.sha256sum
#   SHA256SUMS
#   FILE.sha512
#   FILE.sha512sum
#   SHA512SUMS
#
# Weak checksum files, disabled unless --allow-weak is used:
#   FILE.md5
#   FILE.sha1
#
# Requirements:
#   bash, gpg, sha256sum, sha512sum
#
# Optional:
#   md5sum, sha1sum
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

TARGET_FILE=""
SIGNATURE_FILE=""
KEYRING=""
IMPORT_KEY=""
GNUPGHOME_DIR=""
ALLOW_WEAK=0
CHECK_GPG=1
CHECK_HASH=1
STRICT_FINGERPRINT=0
VERBOSE=0
TRUSTED_FINGERPRINTS=()

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

ok() {
  printf '%s\n' "${C_GREEN}OK:${C_RESET} $*"
}

verbose() {
  [[ "$VERBOSE" -eq 1 ]] && log "$*"
}

usage() {
  cat <<USAGE
${SCRIPT_NAME} ${SCRIPT_VERSION}

Verify a downloaded file with GPG signatures and/or checksums.

Usage:
  ${SCRIPT_NAME} [options] FILE

Options:
  --signature FILE
      Use a specific detached signature file.
      Default: auto-detect FILE.sig or FILE.asc.

  --import-key FILE
      Import a vendor/project public key into a temporary keyring before
      verifying the signature.

  --keyring FILE
      Use an existing GPG keyring file for verification.

  --trusted-fingerprint FINGERPRINT
      Require the signature to be made by this full fingerprint.
      May be specified multiple times.
      Spaces in the fingerprint are ignored.

  --no-gpg
      Skip GPG signature verification.

  --no-hash
      Skip checksum verification.

  --allow-weak
      Allow MD5 and SHA1 checksum verification.
      These are legacy integrity checks only.

  --verbose
      Print extra details.

  -h, --help
      Show this help.

  --version
      Show version information.

Examples:
  ${SCRIPT_NAME} package.tar.gz

  ${SCRIPT_NAME} --import-key vendor-release-key.asc package.tar.gz

  ${SCRIPT_NAME} \\
    --import-key vendor-release-key.asc \\
    --trusted-fingerprint "0123 4567 89AB CDEF 0123 4567 89AB CDEF 0123 4567" \\
    package.tar.gz

  ${SCRIPT_NAME} --no-gpg package.tar.gz

Notes:
  Do not trust a GPG key merely because it was downloaded from a keyserver.
  Verify the vendor key fingerprint from an independent trusted source.

USAGE
}

cleanup() {
  if [[ -n "${GNUPGHOME_DIR:-}" && -d "$GNUPGHOME_DIR" ]]; then
    rm -rf -- "$GNUPGHOME_DIR"
  fi
}

trap cleanup EXIT HUP INT TERM

normalize_fingerprint() {
  printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --signature)
        SIGNATURE_FILE="${2:-}"
        shift 2
        ;;
      --import-key)
        IMPORT_KEY="${2:-}"
        shift 2
        ;;
      --keyring)
        KEYRING="${2:-}"
        shift 2
        ;;
      --trusted-fingerprint)
        TRUSTED_FINGERPRINTS+=("$(normalize_fingerprint "${2:-}")")
        STRICT_FINGERPRINT=1
        shift 2
        ;;
      --no-gpg)
        CHECK_GPG=0
        shift
        ;;
      --no-hash)
        CHECK_HASH=0
        shift
        ;;
      --allow-weak)
        ALLOW_WEAK=1
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
        if [[ -n "$TARGET_FILE" ]]; then
          err "Only one target file may be specified."
          exit 2
        fi
        TARGET_FILE="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$TARGET_FILE" ]]; then
    usage >&2
    exit 2
  fi

  if [[ "$CHECK_GPG" -eq 0 && "$CHECK_HASH" -eq 0 ]]; then
    err "Both --no-gpg and --no-hash were specified. Nothing to verify."
    exit 2
  fi
}

check_requirements() {
  if [[ "$CHECK_GPG" -eq 1 ]]; then
    command_exists gpg || {
      err "Required command not found: gpg"
      exit 1
    }
  fi

  if [[ "$CHECK_HASH" -eq 1 ]]; then
    command_exists sha256sum || warn "sha256sum not found."
    command_exists sha512sum || warn "sha512sum not found."
  fi
}

check_target_file() {
  if [[ ! -f "$TARGET_FILE" ]]; then
    err "Target file not found: $TARGET_FILE"
    exit 1
  fi
}

detect_signature_file() {
  if [[ -n "$SIGNATURE_FILE" ]]; then
    [[ -f "$SIGNATURE_FILE" ]] || {
      err "Signature file not found: $SIGNATURE_FILE"
      exit 1
    }
    return 0
  fi

  if [[ -f "${TARGET_FILE}.sig" ]]; then
    SIGNATURE_FILE="${TARGET_FILE}.sig"
  elif [[ -f "${TARGET_FILE}.asc" ]]; then
    SIGNATURE_FILE="${TARGET_FILE}.asc"
  fi
}

prepare_gnupg_home() {
  GNUPGHOME_DIR="$(mktemp -d)"
  chmod 700 "$GNUPGHOME_DIR"

  if [[ -n "$KEYRING" ]]; then
    [[ -f "$KEYRING" ]] || {
      err "Keyring not found: $KEYRING"
      exit 1
    }
    verbose "Using keyring: $KEYRING"
  fi

  if [[ -n "$IMPORT_KEY" ]]; then
    [[ -f "$IMPORT_KEY" ]] || {
      err "Import key file not found: $IMPORT_KEY"
      exit 1
    }

    log "Importing public key into temporary keyring."
    GNUPGHOME="$GNUPGHOME_DIR" gpg --batch --import "$IMPORT_KEY" >/dev/null
  fi
}

gpg_args() {
  local args=(--batch --status-fd=1)

  if [[ -n "$KEYRING" ]]; then
    args+=(--no-default-keyring --keyring "$KEYRING")
  fi

  printf '%s\0' "${args[@]}"
}

extract_signing_fingerprints() {
  local status_output="$1"

  awk '
    $1 == "[GNUPG:]" && $2 == "VALIDSIG" {
      print toupper($3)
    }
  ' "$status_output"
}

fingerprint_is_trusted() {
  local actual="$1"
  local trusted

  for trusted in "${TRUSTED_FINGERPRINTS[@]}"; do
    if [[ "$actual" == "$trusted" ]]; then
      return 0
    fi
  done

  return 1
}

verify_gpg_signature() {
  if [[ "$CHECK_GPG" -ne 1 ]]; then
    return 0
  fi

  detect_signature_file

  if [[ -z "$SIGNATURE_FILE" ]]; then
    warn "No GPG signature file found for: $TARGET_FILE"
    return 1
  fi

  prepare_gnupg_home

  log "Verifying GPG signature:"
  log "  Signature: $SIGNATURE_FILE"
  log "  File:      $TARGET_FILE"

  local status_file
  status_file="$(mktemp)"

  local verify_rc=0

  if [[ -n "$KEYRING" ]]; then
    GNUPGHOME="$GNUPGHOME_DIR" gpg \
      --batch \
      --status-fd=1 \
      --no-default-keyring \
      --keyring "$KEYRING" \
      --verify "$SIGNATURE_FILE" "$TARGET_FILE" \
      >"$status_file" 2>&1 || verify_rc=$?
  else
    GNUPGHOME="$GNUPGHOME_DIR" gpg \
      --batch \
      --status-fd=1 \
      --verify "$SIGNATURE_FILE" "$TARGET_FILE" \
      >"$status_file" 2>&1 || verify_rc=$?
  fi

  if [[ "$VERBOSE" -eq 1 ]]; then
    sed 's/^/  /' "$status_file"
  fi

  if [[ "$verify_rc" -ne 0 ]]; then
    err "GPG signature verification failed."
    sed 's/^/  /' "$status_file" >&2
    rm -f "$status_file"
    return 1
  fi

  local fingerprints=()
  local fp

  while IFS= read -r fp; do
    [[ -n "$fp" ]] && fingerprints+=("$fp")
  done < <(extract_signing_fingerprints "$status_file")

  rm -f "$status_file"

  if [[ "${#fingerprints[@]}" -eq 0 ]]; then
    err "Could not determine signing fingerprint from GPG status output."
    return 1
  fi

  log "Signing fingerprint(s):"
  for fp in "${fingerprints[@]}"; do
    log "  $fp"
  done

  if [[ "$STRICT_FINGERPRINT" -eq 1 ]]; then
    local matched=0

    for fp in "${fingerprints[@]}"; do
      if fingerprint_is_trusted "$fp"; then
        matched=1
        break
      fi
    done

    if [[ "$matched" -ne 1 ]]; then
      err "Signature was valid, but signer fingerprint did not match trusted fingerprint list."
      return 1
    fi
  else
    warn "Signature is cryptographically valid, but no trusted fingerprint was required."
    warn "This verifies integrity against the imported/local key only; it does not prove vendor identity."
  fi

  ok "GPG signature verification passed."
  return 0
}

checksum_file_contains_target() {
  local sum_file="$1"
  local target_base
  target_base="$(basename -- "$TARGET_FILE")"

  grep -F -- "$target_base" "$sum_file" >/dev/null 2>&1
}

verify_checksum_with_tool() {
  local tool="$1"
  local sum_file="$2"
  local algorithm="$3"

  command_exists "$tool" || {
    warn "$tool not found; skipping $algorithm."
    return 1
  }

  if checksum_file_contains_target "$sum_file"; then
    log "Checking $algorithm checksum file: $sum_file"
    (
      cd "$(dirname -- "$TARGET_FILE")"
      "$tool" -c "$(realpath --relative-to="$(dirname -- "$TARGET_FILE")" "$sum_file")"
    )
  else
    local expected actual
    expected="$(awk '{print $1; exit}' "$sum_file")"
    actual="$("$tool" "$TARGET_FILE" | awk '{print $1}')"

    log "Checking $algorithm checksum file: $sum_file"

    if [[ "${actual,,}" == "${expected,,}" ]]; then
      printf '%s: OK\n' "$TARGET_FILE"
    else
      printf '%s: FAILED\n' "$TARGET_FILE" >&2
      return 1
    fi
  fi
}

verify_hashes() {
  if [[ "$CHECK_HASH" -ne 1 ]]; then
    return 0
  fi

  local found=0
  local failures=0
  local dir
  dir="$(dirname -- "$TARGET_FILE")"

  local sha512_candidates=(
    "${TARGET_FILE}.sha512"
    "${TARGET_FILE}.sha512sum"
    "${dir}/SHA512SUMS"
  )

  local sha256_candidates=(
    "${TARGET_FILE}.sha256"
    "${TARGET_FILE}.sha256sum"
    "${dir}/SHA256SUMS"
  )

  local sha1_candidates=(
    "${TARGET_FILE}.sha1"
    "${TARGET_FILE}.sha1sum"
    "${dir}/SHA1SUMS"
  )

  local md5_candidates=(
    "${TARGET_FILE}.md5"
    "${TARGET_FILE}.md5sum"
    "${dir}/MD5SUMS"
  )

  local file

  for file in "${sha512_candidates[@]}"; do
    if [[ -f "$file" ]]; then
      found=1
      verify_checksum_with_tool sha512sum "$file" "SHA512" || failures=$((failures + 1))
    fi
  done

  for file in "${sha256_candidates[@]}"; do
    if [[ -f "$file" ]]; then
      found=1
      verify_checksum_with_tool sha256sum "$file" "SHA256" || failures=$((failures + 1))
    fi
  done

  if [[ "$ALLOW_WEAK" -eq 1 ]]; then
    for file in "${sha1_candidates[@]}"; do
      if [[ -f "$file" ]]; then
        found=1
        warn "Using weak SHA1 checksum file: $file"
        verify_checksum_with_tool sha1sum "$file" "SHA1" || failures=$((failures + 1))
      fi
    done

    for file in "${md5_candidates[@]}"; do
      if [[ -f "$file" ]]; then
        found=1
        warn "Using weak MD5 checksum file: $file"
        verify_checksum_with_tool md5sum "$file" "MD5" || failures=$((failures + 1))
      fi
    done
  else
    for file in "${sha1_candidates[@]}" "${md5_candidates[@]}"; do
      if [[ -f "$file" ]]; then
        warn "Weak checksum file found but skipped: $file"
        warn "Use --allow-weak only for legacy corruption checks, not security verification."
      fi
    done
  fi

  if [[ "$found" -eq 0 ]]; then
    warn "No supported checksum files found."
    return 1
  fi

  if [[ "$failures" -gt 0 ]]; then
    err "$failures checksum verification step(s) failed."
    return 1
  fi

  ok "Checksum verification passed."
  return 0
}

main() {
  parse_args "$@"
  check_requirements
  check_target_file

  local passed=0
  local failed=0

  if [[ "$CHECK_GPG" -eq 1 ]]; then
    if verify_gpg_signature; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
    fi
  fi

  if [[ "$CHECK_HASH" -eq 1 ]]; then
    if verify_hashes; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
    fi
  fi

  if [[ "$failed" -gt 0 ]]; then
    err "Verification completed with failures."
    exit 1
  fi

  if [[ "$passed" -eq 0 ]]; then
    err "No verification method succeeded."
    exit 1
  fi

  ok "Verification completed successfully."
}

main "$@"