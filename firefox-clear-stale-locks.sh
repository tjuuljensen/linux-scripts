#!/usr/bin/env bash
#
# firefox-clear-stale-locks.sh
#
# Purpose:
#   Remove stale Firefox profile lock files from a local or shared Firefox
#   profile directory.
#
# Description:
#   Firefox creates profile lock files to prevent the same profile from being
#   used by multiple Firefox instances at the same time. On shared home
#   directories, NFS mounts, remote desktop systems, or after an unclean Firefox
#   shutdown, stale lock files can prevent Firefox from starting with an error
#   such as "Firefox is already running, but is not responding."
#
# Safety:
#   Do not run this while Firefox is actually using the profile. If your home
#   directory is shared across machines, this script can only check for local
#   Firefox processes; it cannot prove Firefox is not running on another host.
#
# Default target:
#   ~/.mozilla/firefox
#
# Lock files removed:
#   lock
#   .parentlock
#   parent.lock
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

PROFILE_ROOT="${HOME}/.mozilla/firefox"
DRY_RUN=0
FORCE=0
VERBOSE=0

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

Remove stale Firefox profile lock files.

Usage:
  ${SCRIPT_NAME} [options]

Options:
  --profile-root PATH
      Firefox profile root to scan.
      Default: ~/.mozilla/firefox

  --dry-run
      Show lock files that would be removed without deleting anything.

  --force
      Remove lock files even if a local Firefox process appears to be running.
      Use with care. This cannot detect Firefox running on another NFS/shared
      home-directory host.

  --verbose
      Print extra details.

  -h, --help
      Show this help.

  --version
      Show version information.

Examples:
  ${SCRIPT_NAME} --dry-run

  ${SCRIPT_NAME}

  ${SCRIPT_NAME} --profile-root ~/.mozilla/firefox --force

Recommended safer alternative for multi-machine use:
  firefox -P

USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile-root)
        PROFILE_ROOT="${2:-}"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        VERBOSE=1
        shift
        ;;
      --force)
        FORCE=1
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

  if [[ -z "$PROFILE_ROOT" ]]; then
    err "--profile-root cannot be empty."
    exit 2
  fi
}

check_not_root() {
  if [[ "$EUID" -eq 0 ]]; then
    err "Run this as the normal desktop user, not root."
    exit 1
  fi
}

check_profile_root() {
  if [[ ! -d "$PROFILE_ROOT" ]]; then
    err "Firefox profile root does not exist: $PROFILE_ROOT"
    exit 1
  fi
}

local_firefox_running() {
  pgrep -u "$USER" -x firefox >/dev/null 2>&1 \
    || pgrep -u "$USER" -x firefox-bin >/dev/null 2>&1
}

confirm() {
  local response
  read -r -p "$1 [y/N] " response
  response="${response,,}"
  [[ "$response" =~ ^(y|yes)$ ]]
}

check_firefox_state() {
  if local_firefox_running; then
    warn "A local Firefox process appears to be running."
    warn "Deleting profile locks while Firefox is running can damage or confuse the profile."

    if [[ "$FORCE" -ne 1 ]]; then
      err "Close Firefox first, or rerun with --force if you are certain the locks are stale."
      exit 1
    fi
  fi

  warn "If this profile is on NFS or a shared home directory, this script cannot"
  warn "detect Firefox running on another machine."
}

find_lock_files() {
  find "$PROFILE_ROOT" \
    \( -type f -o -type l \) \
    \( -name 'lock' -o -name '.parentlock' -o -name 'parent.lock' \) \
    -print
}

remove_locks() {
  local found=0
  local file

  while IFS= read -r file; do
    found=1

    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf 'Would remove: %s\n' "$file"
    else
      printf 'Removing: %s\n' "$file"
      rm -- "$file"
    fi
  done < <(find_lock_files)

  if [[ "$found" -eq 0 ]]; then
    ok "No Firefox profile lock files found."
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    ok "Dry run complete."
  else
    ok "Firefox profile lock files removed."
  fi
}

main() {
  parse_args "$@"
  check_not_root
  check_profile_root
  check_firefox_state

  if [[ "$FORCE" -ne 1 && "$DRY_RUN" -ne 1 ]]; then
    if ! confirm "Remove stale Firefox lock files from ${PROFILE_ROOT}?"; then
      log "No changes made."
      exit 0
    fi
  fi

  remove_locks
}

main "$@"