#!/usr/bin/env bash
#
# gb-disk-compact.sh
#
# Purpose:
#   Compact / sparsify qcow2 virtual disk images used by KVM, libvirt, and
#   GNOME Boxes.
#
# Description:
#   Creates a compacted replacement qcow2 image while preserving the original
#   image as a timestamped backup. By default, the script uses virt-sparsify if
#   available, because it is purpose-built for reclaiming free space from guest
#   filesystems. If virt-sparsify is unavailable, it falls back to qemu-img
#   convert.
#
# Important:
#   The VM using the disk must be fully shut down. Do not run this against a
#   disk image used by a running VM, GNOME Boxes, virt-manager, qemu-system, or
#   any other process.
#
# Fedora packages:
#   Required:
#     qemu-img        -> qemu-img
#
#   Recommended:
#     virt-sparsify   -> guestfs-tools
#
# Requirements:
#   Required:
#     bash, qemu-img, readlink, du, awk, grep, sort, wc, chmod, mv, rm
#
#   Recommended:
#     virt-sparsify
#
#   Optional:
#     gnome-boxes, lsof, fuser
#
# Author:
#   Torsten Juul-Jensen
#
# Version:
#   1.0.1
#
# Date:
#   2026-07-02

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.0.1"

METHOD="auto"
COMPRESS=0
COMPRESSION_TYPE="zlib"
DELETE_BACKUP=0
OPEN_BOXES=0
DRY_RUN=0
VERBOSE=0
SKIP_SOURCE_CHECK=0
ALLOW_BACKING_CHAIN_FLATTEN=0
ALLOW_INTERNAL_SNAPSHOT_LOSS=0

DISK=""
TMP_FILES=()

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

cleanup() {
  if [[ "${#TMP_FILES[@]}" -gt 0 ]]; then
    rm -f -- "${TMP_FILES[@]}"
  fi
}

trap cleanup EXIT

usage() {
  cat <<USAGE
${SCRIPT_NAME} ${SCRIPT_VERSION}

Compact / sparsify a qcow2 disk image.

Usage:
  ${SCRIPT_NAME} [options] /path/to/disk.qcow2

Options:
  --method auto|sparsify|convert
      Compaction method.

      auto      Use virt-sparsify if available, otherwise qemu-img convert.
      sparsify  Use virt-sparsify.
      convert   Use qemu-img convert.

      Default: auto

  --compress
      Create a compressed qcow2 output image.

      With qemu-img this uses:
        qemu-img convert -c

      With virt-sparsify this uses:
        virt-sparsify --compress

  --compression-type zlib|zstd
      Compression algorithm for qemu-img convert.
      Default: zlib.
      Ignored by virt-sparsify.

  --delete-backup
      Delete the backup after successful compaction.
      Not recommended until the VM has booted and been checked.

  --open-boxes
      Open GNOME Boxes after successful compaction.

  --skip-source-check
      Skip qemu-img check on the source image before compacting.

  --allow-backing-chain-flatten
      Allow compacting images with a backing file. This creates a standalone
      flattened output image and changes the storage layout.

  --allow-internal-snapshot-loss
      Allow compacting images with qcow2 internal snapshots. Internal snapshots
      are not preserved by this workflow.

  --dry-run
      Show what would be done without changing files.

  --verbose
      Print extra details.

  -h, --help
      Show this help.

  --version
      Show version information.

Examples:
  ${SCRIPT_NAME} ~/.local/share/gnome-boxes/images/win11

  ${SCRIPT_NAME} --method sparsify ~/.local/share/gnome-boxes/images/win11

  ${SCRIPT_NAME} --method convert --compress ~/.local/share/gnome-boxes/images/win11

Notes:
  Shut down the VM before running this script.
  Keep the backup until you have booted and tested the VM.

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
      --method)
        METHOD="${2:-}"
        shift 2
        ;;
      --compress)
        COMPRESS=1
        shift
        ;;
      --compression-type)
        COMPRESSION_TYPE="${2:-}"
        shift 2
        ;;
      --delete-backup)
        DELETE_BACKUP=1
        shift
        ;;
      --open-boxes)
        OPEN_BOXES=1
        shift
        ;;
      --skip-source-check)
        SKIP_SOURCE_CHECK=1
        shift
        ;;
      --allow-backing-chain-flatten)
        ALLOW_BACKING_CHAIN_FLATTEN=1
        shift
        ;;
      --allow-internal-snapshot-loss)
        ALLOW_INTERNAL_SNAPSHOT_LOSS=1
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
        if [[ -n "$DISK" ]]; then
          die "Only one disk image may be specified."
        fi

        DISK="$1"
        shift
        ;;
    esac
  done

  case "$METHOD" in
    auto|sparsify|convert)
      ;;
    *)
      die "--method must be one of: auto, sparsify, convert"
      ;;
  esac

  case "$COMPRESSION_TYPE" in
    zlib|zstd)
      ;;
    *)
      die "--compression-type must be one of: zlib, zstd"
      ;;
  esac

  if [[ -z "$DISK" ]]; then
    err "Missing disk image path."
    usage >&2
    exit 2
  fi
}

validate_requirements() {
  local required_commands=(qemu-img readlink du awk grep sort wc chmod mv rm)
  local cmd

  for cmd in "${required_commands[@]}"; do
    command_exists "$cmd" || die "Required command not found: $cmd"
  done

  if [[ "$METHOD" == "sparsify" ]] && ! command_exists virt-sparsify; then
    die "virt-sparsify is required for --method sparsify. On Fedora, install: sudo dnf install guestfs-tools"
  fi

  if [[ "$METHOD" == "auto" ]]; then
    if command_exists virt-sparsify; then
      METHOD="sparsify"
    else
      METHOD="convert"
      warn "virt-sparsify not found; falling back to qemu-img convert."
      warn "On Fedora, install virt-sparsify with: sudo dnf install guestfs-tools"
    fi
  fi

  verbose "Selected method: $METHOD"

  if [[ "$METHOD" == "convert" && "$COMPRESS" -eq 1 ]]; then
    verbose "Compression enabled: $COMPRESSION_TYPE"
  elif [[ "$METHOD" == "sparsify" && "$COMPRESS" -eq 1 ]]; then
    verbose "Compression enabled through virt-sparsify."
    warn "--compression-type is ignored when using virt-sparsify."
  fi
}

validate_disk() {
  if [[ ! -e "$DISK" ]]; then
    die "File does not exist: $DISK"
  fi

  DISK="$(readlink -f -- "$DISK")"

  if [[ ! -f "$DISK" ]]; then
    die "Not a regular file: $DISK"
  fi

  if [[ ! -r "$DISK" || ! -w "$DISK" ]]; then
    die "Disk must be readable and writable by the current user: $DISK"
  fi

  if ! qemu-img info --output=json "$DISK" | grep -Eq '"format"[[:space:]]*:[[:space:]]*"qcow2"'; then
    die "Image is not detected as qcow2 by qemu-img: $DISK"
  fi
}

check_not_in_use() {
  local used=0

  if command_exists lsof; then
    if lsof -- "$DISK" >/dev/null 2>&1; then
      used=1
    fi
  fi

  if command_exists fuser; then
    if fuser -s -- "$DISK" >/dev/null 2>&1; then
      used=1
    fi
  fi

  if [[ "$used" -eq 1 ]]; then
    err "The disk image appears to be in use: $DISK"
    err "Shut down the VM completely before compacting the disk."
    exit 1
  fi

  if ! command_exists lsof && ! command_exists fuser; then
    warn "Neither lsof nor fuser is available; cannot reliably detect whether the image is in use."
    warn "Make sure the VM is fully shut down before continuing."
  fi
}

has_backing_file() {
  qemu-img info "$DISK" | grep -Eq '^backing file:'
}

has_internal_snapshots() {
  local snapshot_output

  snapshot_output="$(qemu-img snapshot -l -f qcow2 "$DISK" 2>/dev/null || true)"

  awk '
    /^ID[[:space:]]+TAG[[:space:]]+VM SIZE/ {
      in_list = 1
      next
    }

    in_list && NF > 0 {
      found = 1
    }

    END {
      exit found ? 0 : 1
    }
  ' <<< "$snapshot_output"
}

check_image_layout() {
  if has_backing_file && [[ "$ALLOW_BACKING_CHAIN_FLATTEN" -ne 1 ]]; then
    err "Image has a backing file."
    err "Compacting it this way would flatten the backing chain into a standalone image."
    err "Use --allow-backing-chain-flatten only if that is intentional."
    exit 1
  fi

  if has_internal_snapshots && [[ "$ALLOW_INTERNAL_SNAPSHOT_LOSS" -ne 1 ]]; then
    err "Image appears to contain qcow2 internal snapshots."
    err "This workflow does not preserve internal snapshots."
    err "Use --allow-internal-snapshot-loss only if that is acceptable."
    exit 1
  fi
}

check_source_image() {
  if [[ "$SKIP_SOURCE_CHECK" -eq 1 ]]; then
    warn "Skipping source qemu-img check."
    return 0
  fi

  log "Checking source image."
  qemu-img check -f qcow2 "$DISK" >/dev/null
}

print_size_report_before() {
  log "Current image information:"
  qemu-img info -f qcow2 "$DISK" | sed 's/^/  /'

  printf '  Host disk usage: '
  du -h "$DISK" | awk '{print $1}'
}

compact_with_qemu_img() {
  local tmp="$1"
  local args=(convert -p -f qcow2 -O qcow2)

  if [[ "$COMPRESS" -eq 1 ]]; then
    args+=(-c -o "compression_type=${COMPRESSION_TYPE}")
  fi

  args+=("$DISK" "$tmp")

  log "Compacting image with qemu-img convert."
  run qemu-img "${args[@]}"
}

compact_with_virt_sparsify() {
  local tmp="$1"
  local args=(--format qcow2 --convert qcow2)

  if [[ "$COMPRESS" -eq 1 ]]; then
    args+=(--compress)
  fi

  args+=("$DISK" "$tmp")

  log "Compacting image with virt-sparsify."
  run virt-sparsify "${args[@]}"
}

replace_original() {
  local tmp="$1"
  local backup="$2"

  log "Checking compacted image."
  qemu-img check -f qcow2 "$tmp" >/dev/null

  log "Preserving original permissions."
  run chmod --reference="$DISK" "$tmp"

  log "Moving original image to backup:"
  log "  $backup"
  run mv -- "$DISK" "$backup"

  log "Installing compacted image:"
  log "  $DISK"

  if ! run mv -- "$tmp" "$DISK"; then
    err "Failed to install compacted image. Attempting rollback."

    if [[ -e "$backup" && ! -e "$DISK" ]]; then
      mv -- "$backup" "$DISK"
    fi

    exit 1
  fi
}

delete_backup_if_requested() {
  local backup="$1"

  if [[ "$DELETE_BACKUP" -eq 1 ]]; then
    warn "Deleting backup as requested:"
    warn "  $backup"
    run rm -f -- "$backup"
  else
    warn "Backup kept:"
    warn "  $backup"
    warn "Delete it manually only after the VM has booted and been verified."
  fi
}

open_boxes_if_requested() {
  if [[ "$OPEN_BOXES" -eq 1 ]]; then
    if command_exists gnome-boxes; then
      log "Opening GNOME Boxes."
      pidof -q gnome-boxes || nohup gnome-boxes >/dev/null 2>&1 &
    else
      warn "gnome-boxes command not found; skipping."
    fi
  fi
}

main() {
  parse_args "$@"
  validate_requirements
  validate_disk
  check_not_in_use
  check_image_layout
  check_source_image
  print_size_report_before

  local disk_dir
  local disk_base
  local tmp
  local backup
  local timestamp

  disk_dir="$(dirname -- "$DISK")"
  disk_base="$(basename -- "$DISK")"
  timestamp="$(date +%Y%m%d-%H%M%S)"
  tmp="$(mktemp --tmpdir="$disk_dir" ".${disk_base}.compact.XXXXXX.qcow2")"
  backup="${DISK}.bak-${timestamp}"

  TMP_FILES+=("$tmp")

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry run selected. Temporary output would be:"
    log "  $tmp"
    log "Backup would be:"
    log "  $backup"
    exit 0
  fi

  case "$METHOD" in
    sparsify)
      compact_with_virt_sparsify "$tmp"
      ;;
    convert)
      compact_with_qemu_img "$tmp"
      ;;
  esac

  replace_original "$tmp" "$backup"

  log "Checking installed compacted image."
  qemu-img check -f qcow2 "$DISK" >/dev/null

  ok "Compacted successfully."

  log "New image information:"
  qemu-img info -f qcow2 "$DISK" | sed 's/^/  /'

  printf '  Host disk usage: '
  du -h "$DISK" | awk '{print $1}'

  delete_backup_if_requested "$backup"
  open_boxes_if_requested
}

main "$@"