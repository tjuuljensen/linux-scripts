#!/usr/bin/env bash
#
# install-links.sh
#
# Purpose:
#   Create, remove, list, and clean symlinks from a script repository into ~/bin.
#
# Description:
#   By default, this script scans the directory where install-links.sh lives,
#   finds executable regular files, and creates symlinks in ~/bin.
#
#   It is intended for a personal scripts repository such as:
#
#     ~/git/linux-scripts
#
#   and creates links such as:
#
#     ~/bin/urlxray.sh -> ~/git/linux-scripts/urlxray.sh
#
# Actions:
#   create
#       Create symlinks for current source candidates. This is the default.
#
#   remove
#       Remove symlinks in the destination that correspond to current source
#       candidates.
#
#   list
#       List current source candidates.
#
#   clean
#       Destination-driven cleanup. Scans the destination directory and removes
#       stale symlinks that point into the configured source directory.
#
# Cleanup behavior:
#   clean removes destination symlinks pointing into the source directory when:
#     - the target no longer exists;
#     - the target is no longer a regular file;
#     - the target is no longer executable, unless --all is used;
#     - the target no longer matches --glob;
#     - the target is install-links.sh itself;
#     - the target is hidden.
#
# Safety:
#   - Does not overwrite regular files.
#   - Does not remove regular files.
#   - Does not remove directories.
#   - Does not remove symlinks pointing outside the source directory.
#   - --force only replaces existing symlinks.
#   - Skips itself.
#   - Skips hidden files.
#   - Skips directories.
#   - Skips non-executable files unless --all is used.
#
# Version:
#   1.2.0
#
# Date:
#   2026-07-02

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.2.0"

ACTION="create"
SOURCE_DIR=""
DEST_DIR="${HOME}/bin"
FILE_GLOB="*"

FORCE=0
DRY_RUN=0
VERBOSE=0
QUIET=0
INCLUDE_ALL=0
AUTO_CLEAN=0

usage() {
  cat <<USAGE
${SCRIPT_NAME} ${SCRIPT_VERSION}

Create/remove/list/clean symlinks from a scripts repository into ~/bin.

Usage:
  ${SCRIPT_NAME} [action] [options]

Actions:
  create
      Create symlinks. Default action.

  remove
      Remove destination symlinks that correspond to current source candidates.

  list
      List candidate files from the source directory.

  clean
      Remove stale destination symlinks pointing into the source directory.

Options:
  --source DIR
      Source directory containing scripts.
      Default: directory containing this installer.

  --dest DIR
      Destination directory for symlinks.
      Default: ~/bin

  --glob PATTERN
      File glob to match in source directory.
      Default: *

  --all
      Include non-executable regular files.
      Default: only executable regular files are linked/listed/kept.

  --clean
      Run clean before create.
      Only applies to the create action.

  --force
      Replace existing symlinks.
      Does not replace regular files or directories.

  --dry-run
      Show what would be done without changing anything.

  --verbose
      Show extra diagnostics.

  --quiet
      Suppress informational messages.

  -h, --help
      Show this help.

  --version
      Show version information.

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --force
  ${SCRIPT_NAME} --dry-run --force
  ${SCRIPT_NAME} create --dest ~/bin --force
  ${SCRIPT_NAME} list
  ${SCRIPT_NAME} clean --dry-run
  ${SCRIPT_NAME} clean
  ${SCRIPT_NAME} --clean --force
  ${SCRIPT_NAME} remove --dry-run
  ${SCRIPT_NAME} --all --force

Typical workflow:
  # Preview current candidates:
  ${SCRIPT_NAME} list

  # Preview what would be linked:
  ${SCRIPT_NAME} --dry-run --force

  # Install/update links:
  ${SCRIPT_NAME} --force

  # Preview stale symlink cleanup:
  ${SCRIPT_NAME} clean --dry-run

  # Remove stale symlinks:
  ${SCRIPT_NAME} clean

  # Clean stale links, then install/update current links:
  ${SCRIPT_NAME} --clean --force

USAGE
}

log() {
  if [[ "$QUIET" -eq 0 ]]; then
    printf 'INFO: %s\n' "$*" >&2
  fi
}

ok() {
  if [[ "$QUIET" -eq 0 ]]; then
    printf 'OK: %s\n' "$*" >&2
  fi
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

err() {
  printf 'ERROR: %s\n' "$*" >&2
}

verbose() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    log "$*"
  fi
}

die() {
  err "$*"
  exit 1
}

script_dir() {
  local src="${BASH_SOURCE[0]}"
  local dir

  while [[ -L "$src" ]]; do
    dir="$(cd -P "$(dirname -- "$src")" >/dev/null 2>&1 && pwd)"
    src="$(readlink -- "$src")"

    if [[ "$src" != /* ]]; then
      src="${dir}/${src}"
    fi
  done

  cd -P "$(dirname -- "$src")" >/dev/null 2>&1 && pwd
}

absolute_path() {
  local path="$1"

  if [[ -d "$path" ]]; then
    cd -P "$path" >/dev/null 2>&1 && pwd
  else
    local dir
    local base

    dir="$(dirname -- "$path")"
    base="$(basename -- "$path")"

    printf '%s/%s\n' "$(cd -P "$dir" >/dev/null 2>&1 && pwd)" "$base"
  fi
}

expand_tilde() {
  local path="$1"

  case "$path" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOME" "${path#"~/"}"
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      create|remove|list|clean)
        ACTION="$1"
        shift
        ;;
      --source)
        SOURCE_DIR="${2:-}"
        shift 2
        ;;
      --dest)
        DEST_DIR="${2:-}"
        shift 2
        ;;
      --glob)
        FILE_GLOB="${2:-}"
        shift 2
        ;;
      --all)
        INCLUDE_ALL=1
        shift
        ;;
      --clean)
        AUTO_CLEAN=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --verbose)
        VERBOSE=1
        shift
        ;;
      --quiet)
        QUIET=1
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
        die "Unexpected argument: $1"
        ;;
    esac
  done

  if [[ -z "$SOURCE_DIR" ]]; then
    SOURCE_DIR="$(script_dir)"
  fi

  SOURCE_DIR="$(expand_tilde "$SOURCE_DIR")"
  DEST_DIR="$(expand_tilde "$DEST_DIR")"

  SOURCE_DIR="$(absolute_path "$SOURCE_DIR")"

  if [[ -d "$DEST_DIR" ]]; then
    DEST_DIR="$(absolute_path "$DEST_DIR")"
  else
    local dest_parent
    local dest_base

    dest_parent="$(dirname -- "$DEST_DIR")"
    dest_base="$(basename -- "$DEST_DIR")"

    [[ -d "$dest_parent" ]] || die "Destination parent directory does not exist: $dest_parent"

    DEST_DIR="$(absolute_path "$dest_parent")/${dest_base}"
  fi

  [[ -d "$SOURCE_DIR" ]] || die "Source directory does not exist: $SOURCE_DIR"

  case "$ACTION" in
    create|remove|list|clean)
      ;;
    *)
      die "Invalid action: $ACTION"
      ;;
  esac

  if [[ "$AUTO_CLEAN" -eq 1 && "$ACTION" != "create" ]]; then
    warn "--clean only has an effect with the create action."
  fi
}

is_candidate() {
  local path="$1"
  local base

  base="$(basename -- "$path")"

  [[ -f "$path" ]] || return 1
  [[ "$base" != "$SCRIPT_NAME" ]] || return 1
  [[ "$base" != .* ]] || return 1

  if [[ "$INCLUDE_ALL" -eq 0 && ! -x "$path" ]]; then
    return 1
  fi

  case "$base" in
    $FILE_GLOB)
      ;;
    *)
      return 1
      ;;
  esac

  return 0
}

get_candidates() {
  local path

  shopt -s nullglob

  for path in "${SOURCE_DIR}"/${FILE_GLOB}; do
    if is_candidate "$path"; then
      printf '%s\n' "$path"
    fi
  done

  shopt -u nullglob
}

ensure_dest_dir() {
  if [[ -d "$DEST_DIR" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: mkdir -p -- %q\n' "$DEST_DIR"
    return 0
  fi

  mkdir -p -- "$DEST_DIR"
}

symlink_target_absolute() {
  local link="$1"
  local target

  target="$(readlink -- "$link")"

  if [[ "$target" != /* ]]; then
    target="$(absolute_path "$(dirname -- "$link")/$target")"
  fi

  printf '%s\n' "$target"
}

same_symlink_target() {
  local link="$1"
  local target="$2"
  local current=""

  [[ -L "$link" ]] || return 1

  current="$(symlink_target_absolute "$link")"

  [[ "$current" == "$target" ]]
}

path_is_inside_source_dir() {
  local path="$1"

  case "$path" in
    "$SOURCE_DIR"/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

target_is_current_candidate() {
  local target="$1"

  [[ -e "$target" ]] || return 1
  [[ -f "$target" ]] || return 1

  is_candidate "$target"
}

create_one_link() {
  local src="$1"
  local base
  local dst

  base="$(basename -- "$src")"
  dst="${DEST_DIR}/${base}"

  if same_symlink_target "$dst" "$src"; then
    log "Already installed: $base"
    return 0
  fi

  if [[ -e "$dst" || -L "$dst" ]]; then
    if [[ -L "$dst" && "$FORCE" -eq 1 ]]; then
      log "Replacing symlink: $dst"

      if [[ "$DRY_RUN" -eq 1 ]]; then
        printf 'DRY-RUN: rm -f -- %q\n' "$dst"
      else
        rm -f -- "$dst"
      fi
    else
      warn "Skipping existing path: $dst"
      warn "Use --force to replace symlinks only. Regular files/directories are never overwritten."
      return 0
    fi
  fi

  log "Linking: $dst -> $src"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: ln -s -- %q %q\n' "$src" "$dst"
    return 0
  fi

  ln -s -- "$src" "$dst"
}

action_create() {
  local src
  local count=0

  ensure_dest_dir

  while IFS= read -r src; do
    create_one_link "$src"
    count=$((count + 1))
  done < <(get_candidates)

  ok "Create action completed. Candidates processed: $count"
}

remove_one_link() {
  local src="$1"
  local base
  local dst

  base="$(basename -- "$src")"
  dst="${DEST_DIR}/${base}"

  if [[ ! -L "$dst" ]]; then
    verbose "No symlink to remove: $dst"
    return 0
  fi

  if same_symlink_target "$dst" "$src"; then
    log "Removing: $dst"

    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf 'DRY-RUN: rm -f -- %q\n' "$dst"
    else
      rm -f -- "$dst"
    fi
  else
    warn "Skipping symlink not pointing to source candidate: $dst"
  fi
}

action_remove() {
  local src
  local count=0

  while IFS= read -r src; do
    remove_one_link "$src"
    count=$((count + 1))
  done < <(get_candidates)

  ok "Remove action completed. Candidates processed: $count"
}

clean_one_link() {
  local link="$1"
  local target
  local reason=""

  [[ -L "$link" ]] || return 0

  target="$(symlink_target_absolute "$link")"

  if ! path_is_inside_source_dir "$target"; then
    verbose "Keeping symlink outside source dir: $link -> $target"
    return 0
  fi

  if [[ ! -e "$target" ]]; then
    reason="target missing"
  elif [[ ! -f "$target" ]]; then
    reason="target is not a regular file"
  elif [[ "$INCLUDE_ALL" -eq 0 && ! -x "$target" ]]; then
    reason="target is no longer executable"
  elif ! target_is_current_candidate "$target"; then
    reason="target no longer matches current candidate rules"
  fi

  if [[ -z "$reason" ]]; then
    verbose "Keeping valid link: $link -> $target"
    return 0
  fi

  log "Cleaning stale link: $link -> $target ($reason)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: rm -f -- %q\n' "$link"
  else
    rm -f -- "$link"
  fi
}

action_clean() {
  local link
  local count=0
  local cleaned=0

  if [[ ! -d "$DEST_DIR" ]]; then
    verbose "Destination directory does not exist: $DEST_DIR"
    ok "Clean action completed. Links inspected: 0. Links cleaned: 0"
    return 0
  fi

  shopt -s nullglob

  for link in "$DEST_DIR"/*; do
    if [[ -L "$link" ]]; then
      count=$((count + 1))

      if clean_one_link "$link"; then
        :
      fi
    fi
  done

  shopt -u nullglob

  # Count cleaned links by doing the removal inside clean_one_link, but do not
  # attempt to reconstruct exact count from dry-run/non-dry-run cases here.
  # The per-link log lines are the authoritative cleanup report.
  ok "Clean action completed. Links inspected: $count"
}

action_list() {
  local src

  log "Source directory: $SOURCE_DIR"
  log "Destination directory: $DEST_DIR"
  log "File glob: $FILE_GLOB"

  while IFS= read -r src; do
    printf '%s\n' "$(basename -- "$src")"
  done < <(get_candidates)
}

main() {
  parse_args "$@"

  case "$ACTION" in
    create)
      if [[ "$AUTO_CLEAN" -eq 1 ]]; then
        action_clean
      fi

      action_create
      ;;
    remove)
      action_remove
      ;;
    clean)
      action_clean
      ;;
    list)
      action_list
      ;;
  esac
}

main "$@"