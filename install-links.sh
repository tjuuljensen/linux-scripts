#!/usr/bin/env bash
#
# install-links.sh
#
# Purpose:
#   Install executable files from this script's source directory by creating
#   symbolic links in a destination directory.
#
# Description:
#   This script is intended for small personal script repositories. It scans a
#   source directory for executable regular files and creates symlinks to them
#   in a destination directory, defaulting to ~/bin.
#
#   It can also remove symlinks in the destination directory that point back
#   into the source directory.
#
# Scope:
#   - Installs executable regular files only.
#   - Does not install directories.
#   - Does not install the installer script itself.
#   - Does not overwrite regular destination files.
#
# Safety:
#   - Supports --dry-run.
#   - Refuses to replace existing non-symlink files.
#   - By default, existing symlinks are only updated if --force is used.
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

SCRIPT_NAME="$(basename -- "$0")"
SCRIPT_VERSION="1.0.0"

DESTINATION_DIR="${HOME}/bin"
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
FILE_GLOB="*"

ACTION="create"
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

Install executable files from a source directory by creating symlinks in a
destination directory.

Usage:
  ${SCRIPT_NAME} [options]
  ${SCRIPT_NAME} create [options]
  ${SCRIPT_NAME} remove [options]
  ${SCRIPT_NAME} list [options]

Actions:
  create
      Create symlinks for executable files.
      This is the default action.

  remove
      Remove symlinks in the destination directory that point into the source
      directory.

  list
      Show executable files that would be installable from the source directory.

Options:
  -d, --dest DIR
      Destination directory for symlinks.
      Default: ~/bin

  -s, --source DIR
      Source directory to scan.
      Default: directory containing this installer script.

  -g, --glob PATTERN
      Shell glob used to select files inside the source directory.
      Default: "*"

  -f, --force
      Replace existing symlinks in the destination directory.
      Regular files are still not overwritten.

  -n, --dry-run
      Show what would be done without changing anything.

  -v, --verbose
      Print extra details.

  -h, --help
      Show this help.

  --version
      Show version information.

Examples:
  ${SCRIPT_NAME}

  ${SCRIPT_NAME} create --dest ~/.local/bin

  ${SCRIPT_NAME} remove --dest ~/bin

  ${SCRIPT_NAME} list

  ${SCRIPT_NAME} create --glob "*.sh"

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

parse_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      create|remove|list)
        ACTION="$1"
        shift
        ;;
    esac
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--dest)
        [[ $# -ge 2 ]] || die "Missing argument for $1."
        DESTINATION_DIR="$2"
        shift 2
        ;;
      -s|--source)
        [[ $# -ge 2 ]] || die "Missing argument for $1."
        SOURCE_DIR="$2"
        shift 2
        ;;
      -g|--glob)
        [[ $# -ge 2 ]] || die "Missing argument for $1."
        FILE_GLOB="$2"
        shift 2
        ;;
      -f|--force)
        FORCE=1
        shift
        ;;
      -n|--dry-run)
        DRY_RUN=1
        VERBOSE=1
        shift
        ;;
      -v|--verbose)
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
        die "Unknown argument: $1"
        ;;
    esac
  done
}

normalize_paths() {
  SOURCE_DIR="$(cd -- "$SOURCE_DIR" >/dev/null 2>&1 && pwd -P)" \
    || die "Source directory does not exist: $SOURCE_DIR"

  DESTINATION_DIR="${DESTINATION_DIR/#\~/${HOME}}"

  if [[ -e "$DESTINATION_DIR" && ! -d "$DESTINATION_DIR" ]]; then
    die "Destination exists but is not a directory: $DESTINATION_DIR"
  fi
}

ensure_destination_dir() {
  if [[ ! -d "$DESTINATION_DIR" ]]; then
    log "Creating destination directory: $DESTINATION_DIR"
    run mkdir -p -- "$DESTINATION_DIR"
  fi
}

is_installer_script() {
  local path="$1"
  local real_path
  local real_self

  real_path="$(realpath -- "$path")"
  real_self="$(realpath -- "${BASH_SOURCE[0]}")"

  [[ "$real_path" == "$real_self" ]]
}

iter_installable_files() {
  local path

  shopt -s nullglob dotglob

  for path in "$SOURCE_DIR"/$FILE_GLOB; do
    [[ -f "$path" ]] || continue
    [[ -x "$path" ]] || continue
    is_installer_script "$path" && continue
    printf '%s\n' "$path"
  done

  shopt -u nullglob dotglob
}

list_installable() {
  local found=0
  local path

  log "Source directory: $SOURCE_DIR"
  log "Destination directory: $DESTINATION_DIR"
  log "File glob: $FILE_GLOB"

  while IFS= read -r path; do
    found=1
    printf '%s\n' "$(basename -- "$path")"
  done < <(iter_installable_files)

  if [[ "$found" -eq 0 ]]; then
    warn "No installable executable files found."
  fi
}

create_symlink() {
  local source_path="$1"
  local link_name
  local link_path
  local existing_target

  link_name="$(basename -- "$source_path")"
  link_path="${DESTINATION_DIR}/${link_name}"

  if [[ -e "$link_path" || -L "$link_path" ]]; then
    if [[ -L "$link_path" ]]; then
      existing_target="$(readlink -- "$link_path")"

      if [[ "$(realpath -m -- "$link_path")" == "$(realpath -m -- "$source_path")" ]]; then
        verbose "Already installed: $link_name"
        return 0
      fi

      if [[ "$FORCE" -eq 1 ]]; then
        warn "Replacing symlink: $link_path -> $existing_target"
        run rm -f -- "$link_path"
      else
        warn "Skipping existing symlink: $link_path"
        warn "Use --force to replace it."
        return 0
      fi
    else
      warn "Skipping existing non-symlink file: $link_path"
      return 0
    fi
  fi

  log "Linking: $link_path -> $source_path"
  run ln -s -- "$source_path" "$link_path"
}

create_symlinks() {
  local found=0
  local path

  ensure_destination_dir

  while IFS= read -r path; do
    found=1
    create_symlink "$path"
  done < <(iter_installable_files)

  if [[ "$found" -eq 0 ]]; then
    warn "No installable executable files found."
  else
    ok "Create action completed."
  fi
}

remove_symlinks() {
  local found=0
  local link
  local target

  if [[ ! -d "$DESTINATION_DIR" ]]; then
    warn "Destination directory does not exist: $DESTINATION_DIR"
    return 0
  fi

  while IFS= read -r -d '' link; do
    target="$(realpath -m -- "$link")"

    if [[ "$target" == "$SOURCE_DIR/"* ]]; then
      found=1
      log "Removing symlink: $link -> $target"
      run rm -f -- "$link"
    else
      verbose "Keeping unrelated symlink: $link -> $target"
    fi
  done < <(find "$DESTINATION_DIR" -maxdepth 1 -type l -print0)

  if [[ "$found" -eq 0 ]]; then
    warn "No matching symlinks found."
  else
    ok "Remove action completed."
  fi
}

main() {
  parse_args "$@"
  normalize_paths

  case "$ACTION" in
    create)
      create_symlinks
      ;;
    remove)
      remove_symlinks
      ;;
    list)
      list_installable
      ;;
    *)
      die "Unknown action: $ACTION"
      ;;
  esac
}

main "$@"