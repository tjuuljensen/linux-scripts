#!/usr/bin/env bash
#
# list-group-members.sh
#
# Purpose:
#   Display members of a Unix/Linux group.
#
# Description:
#   This script lists users that belong to a group, including:
#
#     1. Supplementary members listed in the group database.
#     2. Users whose primary GID matches the group.
#
#   It uses getent instead of reading /etc/group directly, so it works with the
#   system's configured Name Service Switch sources where enumeration is
#   supported.
#
# Scope:
#   Linux/NSS-oriented helper script.
#
# Notes:
#   Some remote identity sources may not support full passwd/group enumeration.
#   In that case, primary-group member discovery may be incomplete.
#
# Requirements:
#   bash, getent, awk, sort
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

GROUP_NAME=""
LIST_GROUPS=0
PRIMARY_ONLY=0
SUPPLEMENTARY_ONLY=0
VERBOSE=0

TMPFILE=""

cleanup() {
  if [[ -n "${TMPFILE:-}" && -f "$TMPFILE" ]]; then
    rm -f -- "$TMPFILE"
  fi
}

trap cleanup EXIT

usage() {
  cat <<USAGE
${SCRIPT_NAME} ${SCRIPT_VERSION}

Display members of a Unix/Linux group.

Usage:
  ${SCRIPT_NAME} [options] GROUP
  ${SCRIPT_NAME} --list-groups

Options:
  --primary-only
      Show only users whose primary GID is the group.

  --supplementary-only
      Show only users explicitly listed as supplementary group members.

  --list-groups
      List all group names visible through getent group.

  --verbose
      Show group name, GID, and member source.

  -h, --help
      Show this help.

  --version
      Show version information.

Examples:
  ${SCRIPT_NAME} wheel

  ${SCRIPT_NAME} docker

  ${SCRIPT_NAME} --verbose sudo

  ${SCRIPT_NAME} --primary-only users

  ${SCRIPT_NAME} --list-groups

USAGE
}

err() {
  printf 'ERROR: %s\n' "$*" >&2
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --primary-only)
        PRIMARY_ONLY=1
        shift
        ;;
      --supplementary-only)
        SUPPLEMENTARY_ONLY=1
        shift
        ;;
      --list-groups)
        LIST_GROUPS=1
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
        if [[ -n "$GROUP_NAME" ]]; then
          err "Only one group name may be specified."
          exit 2
        fi
        GROUP_NAME="$1"
        shift
        ;;
    esac
  done

  if [[ "$PRIMARY_ONLY" -eq 1 && "$SUPPLEMENTARY_ONLY" -eq 1 ]]; then
    err "--primary-only and --supplementary-only cannot be used together."
    exit 2
  fi

  if [[ "$LIST_GROUPS" -eq 0 && -z "$GROUP_NAME" ]]; then
    usage >&2
    exit 2
  fi
}

check_requirements() {
  local cmd

  for cmd in getent awk sort; do
    command_exists "$cmd" || {
      err "Required command not found: $cmd"
      exit 1
    }
  done
}

list_groups() {
  getent group | awk -F: '{ print $1 }' | sort
}

get_group_record() {
  getent group "$GROUP_NAME" || true
}

get_group_gid() {
  local group_record="$1"

  awk -F: '{ print $3 }' <<< "$group_record"
}

print_supplementary_members() {
  local group_record="$1"

  awk -F: '
    $4 != "" {
      n = split($4, users, ",")
      for (i = 1; i <= n; i++) {
        if (users[i] != "") {
          print users[i] "\tsupplementary"
        }
      }
    }
  ' <<< "$group_record"
}

print_primary_members() {
  local gid="$1"

  getent passwd \
    | awk -F: -v gid="$gid" '
        $4 == gid {
          print $1 "\tprimary"
        }
      '
}

list_members() {
  local group_record
  local gid

  group_record="$(get_group_record)"

  if [[ -z "$group_record" ]]; then
    err "Group not found through getent: $GROUP_NAME"
    exit 1
  fi

  gid="$(get_group_gid "$group_record")"

  if [[ "$VERBOSE" -eq 1 ]]; then
    printf 'Group: %s\n' "$GROUP_NAME"
    printf 'GID:   %s\n' "$gid"
    printf '\n'
    printf '%-24s %s\n' "USER" "SOURCE"
    printf '%-24s %s\n' "----" "------"
  fi

  TMPFILE="$(mktemp)"

  if [[ "$PRIMARY_ONLY" -ne 1 ]]; then
    print_supplementary_members "$group_record" >> "$TMPFILE"
  fi

  if [[ "$SUPPLEMENTARY_ONLY" -ne 1 ]]; then
    print_primary_members "$gid" >> "$TMPFILE"
  fi

  if [[ ! -s "$TMPFILE" ]]; then
    exit 0
  fi

  if [[ "$VERBOSE" -eq 1 ]]; then
    sort -u "$TMPFILE" \
      | awk -F'\t' '{ printf "%-24s %s\n", $1, $2 }'
  else
    awk -F'\t' '{ print $1 }' "$TMPFILE" | sort -u
  fi
}

main() {
  parse_args "$@"
  check_requirements

  if [[ "$LIST_GROUPS" -eq 1 ]]; then
    list_groups
  else
    list_members
  fi
}

main "$@"