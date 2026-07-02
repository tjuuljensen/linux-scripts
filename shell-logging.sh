#!/usr/bin/env bash
#
# shell-logging.sh
#
# Purpose:
#   Small Bash logging helper library for personal shell scripts.
#
# Description:
#   Source this file from another Bash script to get consistent timestamped
#   logging functions with levels, caller names, optional stderr mirroring, and
#   safe default log-file handling.
#
# Usage:
#   source /path/to/liblog.sh
#
#   log_init                         # default log file
#   log_init "/path/to/script.log"    # explicit log file
#
#   log_info "Starting job"
#   log_debug "Debug details"
#   log_warn "Something looks suspicious"
#   log_error "Something failed"
#
#   my_function() {
#     log_entry
#     log_debug "Doing work"
#     log_exit
#   }
#
# Environment variables:
#   SCRIPT_LOG
#     Explicit log file path. Used if log_init is called without an argument.
#
#   LOG_LEVEL
#     Minimum level to write. One of:
#       DEBUG, INFO, WARN, ERROR, OFF
#     Default: INFO
#
#   LOG_TO_STDERR
#     If set to 1, mirror log lines to stderr.
#     Default: 0
#
# Default log location:
#   ${XDG_STATE_HOME:-$HOME/.local/state}/shell-scripts/<script-name>.log
#
# Compatibility:
#   Bash only. This library intentionally uses Bash call-stack information.
#
# Author:
#   Torsten Juul-Jensen
#
# Version:
#   1.0.0
#
# Date:
#   2026-07-02

# Refuse POSIX sh/dash early if someone tries to source this from /bin/sh.
if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s\n' "ERROR: liblog.sh requires Bash." >&2
  return 2 2>/dev/null || exit 2
fi

LIBLOG_VERSION="1.0.0"

# Do not set shell options here.
# This file is intended to be sourced, and changing set -euo pipefail or IFS
# from a library would unexpectedly alter the parent script.

SCRIPT_LOG="${SCRIPT_LOG:-}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_TO_STDERR="${LOG_TO_STDERR:-0}"

_log_script_name() {
  local name

  name="$(basename -- "$0")"
  name="${name%.*}"

  if [[ -z "$name" || "$name" == "bash" ]]; then
    name="interactive-shell"
  fi

  printf '%s\n' "$name"
}

_log_default_file() {
  local script_name
  local state_dir

  script_name="$(_log_script_name)"

  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    state_dir="${XDG_STATE_HOME}/shell-scripts"
  elif [[ -n "${HOME:-}" ]]; then
    state_dir="${HOME}/.local/state/shell-scripts"
  else
    state_dir="/tmp/shell-scripts"
  fi

  printf '%s/%s.log\n' "$state_dir" "$script_name"
}

_log_timestamp() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

_log_level_num() {
  case "${1^^}" in
    DEBUG) printf '10\n' ;;
    INFO)  printf '20\n' ;;
    WARN|WARNING) printf '30\n' ;;
    ERROR|ERR) printf '40\n' ;;
    OFF|NONE) printf '99\n' ;;
    *) printf '20\n' ;;
  esac
}

_log_should_log() {
  local message_level
  local configured_level

  message_level="$(_log_level_num "$1")"
  configured_level="$(_log_level_num "${LOG_LEVEL:-INFO}")"

  [[ "$message_level" -ge "$configured_level" ]]
}

log_init() {
  local requested_log
  local log_dir

  requested_log="${1:-${SCRIPT_LOG:-}}"

  if [[ -z "$requested_log" ]]; then
    requested_log="$(_log_default_file)"
  fi

  SCRIPT_LOG="$requested_log"
  log_dir="$(dirname -- "$SCRIPT_LOG")"

  if [[ ! -d "$log_dir" ]]; then
    mkdir -p -- "$log_dir" || {
      printf '%s\n' "ERROR: could not create log directory: $log_dir" >&2
      return 1
    }
  fi

  : >> "$SCRIPT_LOG" || {
    printf '%s\n' "ERROR: could not write to log file: $SCRIPT_LOG" >&2
    return 1
  }

  chmod 600 "$SCRIPT_LOG" 2>/dev/null || true

  return 0
}

_log_ensure_init() {
  if [[ -z "${SCRIPT_LOG:-}" ]]; then
    log_init
  else
    local log_dir
    log_dir="$(dirname -- "$SCRIPT_LOG")"

    if [[ ! -d "$log_dir" ]]; then
      mkdir -p -- "$log_dir" || return 1
    fi

    : >> "$SCRIPT_LOG" || return 1
  fi
}

_log_write() {
  local level="$1"
  local caller="$2"
  local message="$3"
  local timestamp
  local line

  _log_should_log "$level" || return 0
  _log_ensure_init || {
    printf '%s\n' "ERROR: logging is not initialized and could not be initialized." >&2
    return 1
  }

  timestamp="$(_log_timestamp)"
  line="[$timestamp] [$level] [$caller] $message"

  printf '%s\n' "$line" >> "$SCRIPT_LOG"

  if [[ "${LOG_TO_STDERR:-0}" == "1" ]]; then
    printf '%s\n' "$line" >&2
  fi
}

log_set_file() {
  log_init "$1"
}

log_set_level() {
  case "${1^^}" in
    DEBUG|INFO|WARN|WARNING|ERROR|ERR|OFF|NONE)
      LOG_LEVEL="${1^^}"
      ;;
    *)
      printf '%s\n' "ERROR: invalid log level: $1" >&2
      return 2
      ;;
  esac
}

log_debug() {
  local caller="${FUNCNAME[1]:-main}"
  _log_write "DEBUG" "$caller" "$*"
}

log_info() {
  local caller="${FUNCNAME[1]:-main}"
  _log_write "INFO" "$caller" "$*"
}

log_warn() {
  local caller="${FUNCNAME[1]:-main}"
  _log_write "WARN" "$caller" "$*"
}

log_error() {
  local caller="${FUNCNAME[1]:-main}"
  _log_write "ERROR" "$caller" "$*"
}

log_entry() {
  local caller="${FUNCNAME[1]:-main}"
  _log_write "DEBUG" "$caller" "> ${caller}"
}

log_exit() {
  local caller="${FUNCNAME[1]:-main}"
  _log_write "DEBUG" "$caller" "< ${caller}"
}

log_script_entry() {
  local script_name
  script_name="$(_log_script_name)"
  _log_write "DEBUG" "$script_name" "> ${script_name}"
}

log_script_exit() {
  local script_name
  script_name="$(_log_script_name)"
  _log_write "DEBUG" "$script_name" "< ${script_name}"
}

log_die() {
  local exit_code=1
  local message

  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    exit_code="$1"
    shift
  fi

  message="$*"

  log_error "$message"
  printf '%s\n' "ERROR: $message" >&2
  exit "$exit_code"
}

# Compatibility wrappers for scripts using the old names.
# New scripts should prefer the lowercase log_* functions.

SCRIPTENTRY() {
  log_script_entry
}

SCRIPTEXIT() {
  log_script_exit
}

ENTRY() {
  log_entry
}

EXIT() {
  log_exit
}

INFO() {
  log_info "$@"
}

DEBUG() {
  log_debug "$@"
}

ERROR() {
  log_error "$@"
}

liblog_help() {
  cat <<USAGE
liblog.sh ${LIBLOG_VERSION}

Source this file from a Bash script:

  source /path/to/liblog.sh

Basic use:

  log_init
  log_info "Starting"
  log_debug "Details"
  log_warn "Warning"
  log_error "Error"

Environment:

  SCRIPT_LOG=/path/to/script.log
  LOG_LEVEL=DEBUG|INFO|WARN|ERROR|OFF
  LOG_TO_STDERR=0|1

This file is a library. It should normally be sourced, not executed.
USAGE
}

liblog_self_test() {
  LOG_LEVEL=DEBUG
  LOG_TO_STDERR=1
  log_init "${TMPDIR:-/tmp}/liblog-self-test.log"

  log_script_entry
  log_info "Info test"
  log_debug "Debug test"
  log_warn "Warn test"
  log_error "Error test"

  test_function() {
    log_entry
    log_debug "Inside test function"
    log_exit
  }

  test_function
  log_script_exit

  printf 'Self-test log written to: %s\n' "$SCRIPT_LOG"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    -h|--help|"")
      liblog_help
      ;;
    --version)
      printf 'liblog.sh %s\n' "$LIBLOG_VERSION"
      ;;
    --self-test)
      liblog_self_test
      ;;
    *)
      printf '%s\n' "ERROR: unknown argument: $1" >&2
      liblog_help >&2
      exit 2
      ;;
  esac
fi