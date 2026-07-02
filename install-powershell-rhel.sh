#!/usr/bin/env bash
#
# install-powershell-rhel.sh
#
# Purpose:
#   Install Microsoft PowerShell on RHEL-compatible systems using the Microsoft
#   Linux package repository.
#
# Description:
#   Detects the local RHEL-compatible major version, installs the matching
#   Microsoft repository package, refreshes package metadata, and installs
#   PowerShell.
#
# Supported target family:
#   RHEL-compatible rpm/dnf systems such as:
#     - Red Hat Enterprise Linux
#     - Rocky Linux
#     - AlmaLinux
#     - Oracle Linux, where compatible
#
# Notes:
#   This installs the stable "powershell" package, which provides the "pwsh"
#   command.
#
#   The script does not run a full system upgrade by default. It only refreshes
#   repository metadata and installs PowerShell.
#
# Requirements:
#   bash, curl, rpm, dnf, sudo
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

DRY_RUN=0
VERBOSE=0
SKIP_REPO_INSTALL=0
ASSUME_YES=0
DO_UPGRADE=0
RHEL_MAJOR=""

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

Install Microsoft PowerShell on RHEL-compatible systems.

Usage:
  ${SCRIPT_NAME} [options]

Options:
  --rhel-major 7|8|9|10
      Override detected RHEL-compatible major version.

  --skip-repo-install
      Do not install the Microsoft repository RPM.
      Use this if the repository is already configured.

  --upgrade
      Run dnf upgrade after installing the Microsoft repository package.
      By default, this script does not run a full system upgrade.

  -y, --yes
      Pass -y to dnf/rpm operations where applicable.

  --dry-run
      Print commands without executing them.

  --verbose
      Print extra detection details.

  -h, --help
      Show this help.

  --version
      Show version information.

Examples:
  ${SCRIPT_NAME}

  ${SCRIPT_NAME} --yes

  ${SCRIPT_NAME} --dry-run --verbose

  ${SCRIPT_NAME} --rhel-major 9 --yes

USAGE
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

die() {
  err "$*"
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rhel-major)
        RHEL_MAJOR="${2:-}"
        shift 2
        ;;
      --skip-repo-install)
        SKIP_REPO_INSTALL=1
        shift
        ;;
      --upgrade)
        DO_UPGRADE=1
        shift
        ;;
      -y|--yes)
        ASSUME_YES=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        VERBOSE=1
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

  if [[ -n "$RHEL_MAJOR" && ! "$RHEL_MAJOR" =~ ^(7|8|9|10)$ ]]; then
    die "--rhel-major must be one of: 7, 8, 9, 10"
  fi
}

check_requirements() {
  local cmd

  for cmd in curl rpm dnf sudo; do
    command_exists "$cmd" || die "Required command not found: $cmd"
  done

  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
}

detect_rhel_major() {
  if [[ -n "$RHEL_MAJOR" ]]; then
    verbose "Using overridden RHEL major version: $RHEL_MAJOR"
    return 0
  fi

  # shellcheck disable=SC1091
  source /etc/os-release

  local version_id="${VERSION_ID:-}"
  local id="${ID:-}"
  local id_like="${ID_LIKE:-}"
  local major="${version_id%%.*}"

  verbose "Detected ID: ${id:-unknown}"
  verbose "Detected ID_LIKE: ${id_like:-unknown}"
  verbose "Detected VERSION_ID: ${version_id:-unknown}"

  [[ -n "$major" && "$major" =~ ^[0-9]+$ ]] || {
    die "Could not determine OS major version from /etc/os-release"
  }

  case " $id $id_like " in
    *" rhel "*|*" fedora "*|*" centos "*)
      ;;
    *)
      warn "This does not clearly identify as a RHEL-compatible system:"
      warn "  ID=${id:-unknown}"
      warn "  ID_LIKE=${id_like:-unknown}"
      warn "Continuing because dnf/rpm are present."
      ;;
  esac

  case "$major" in
    7|8|9|10)
      RHEL_MAJOR="$major"
      ;;
    *)
      die "Unsupported or untested RHEL-compatible major version: $major"
      ;;
  esac
}

repo_package_url() {
  printf 'https://packages.microsoft.com/config/rhel/%s/packages-microsoft-prod.rpm\n' "$RHEL_MAJOR"
}

is_repo_installed() {
  rpm -q packages-microsoft-prod >/dev/null 2>&1
}

install_repo_package() {
  local url
  local tmpdir
  local rpm_path

  if [[ "$SKIP_REPO_INSTALL" -eq 1 ]]; then
    log "Skipping Microsoft repository package installation."
    return 0
  fi

  if is_repo_installed; then
    ok "Microsoft repository package is already installed."
    return 0
  fi

  url="$(repo_package_url)"
  tmpdir="$(mktemp -d)"
  rpm_path="${tmpdir}/packages-microsoft-prod.rpm"

  cleanup_repo_tmp() {
    rm -rf -- "$tmpdir"
  }

  trap cleanup_repo_tmp RETURN

  log "Downloading Microsoft repository package:"
  log "  $url"

  run curl -fL --retry 3 --connect-timeout 10 --output "$rpm_path" "$url"

  log "Installing Microsoft repository package."
  run sudo rpm -Uvh "$rpm_path"
}

refresh_metadata() {
  log "Refreshing dnf metadata."
  run sudo dnf makecache
}

upgrade_system_if_requested() {
  local dnf_args=()

  [[ "$DO_UPGRADE" -eq 1 ]] || return 0

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    dnf_args+=(-y)
  fi

  log "Running dnf upgrade because --upgrade was requested."
  run sudo dnf upgrade "${dnf_args[@]}"
}

install_powershell() {
  local dnf_args=()

  if rpm -q powershell >/dev/null 2>&1; then
    ok "PowerShell is already installed."
    return 0
  fi

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    dnf_args+=(-y)
  fi

  log "Installing PowerShell."
  run sudo dnf install "${dnf_args[@]}" powershell
}

verify_installation() {
  if command_exists pwsh; then
    ok "PowerShell installed."
    pwsh --version || true
  else
    warn "PowerShell package installation completed, but pwsh was not found in PATH."
  fi
}

main() {
  parse_args "$@"
  check_requirements
  detect_rhel_major

  log "Using RHEL-compatible major version: $RHEL_MAJOR"

  install_repo_package
  refresh_metadata
  upgrade_system_if_requested
  install_powershell
  verify_installation
}

main "$@"