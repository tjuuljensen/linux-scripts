#!/bin/sh
#
# cron-edit.sh
#
# Purpose:
#   Small command-line helper for listing, adding, and removing entries from
#   the current user's crontab.
#
# Description:
#   This script edits the current user's crontab by exporting it with
#   "crontab -l", modifying a temporary file, and installing the modified file
#   with "crontab <file>".
#
# Scope:
#   Intended for simple per-user cron jobs. For more complex scheduled tasks
#   that require logging, dependencies, missed-run handling, or better service
#   management, consider a systemd user timer instead.
#
# Safety:
#   - Does not edit /etc/crontab or system-wide cron directories.
#   - Creates an optional backup before modifying the crontab.
#   - Refuses duplicate jobs by default.
#   - Removes entries by visible line number from "list" output.
#
# Author:
#   Torsten Juul-Jensen
#
# Version:
#   1.0.0
#
# Date:
#   2026-07-02

set -u

SCRIPT_NAME=${0##*/}
SCRIPT_VERSION="1.0.0"

BACKUP=0
DRY_RUN=0
FORCE=0
COMMAND=
ARG=

usage() {
    cat <<USAGE_END
${SCRIPT_NAME} ${SCRIPT_VERSION}

Usage:
  ${SCRIPT_NAME} [options] add "cron-spec"
  ${SCRIPT_NAME} [options] list
  ${SCRIPT_NAME} [options] remove LINE_NUMBER

Options:
  --backup
      Save the current crontab before modifying it.

  --dry-run
      Show the resulting crontab without installing it.

  --force
      Allow adding a duplicate cron line.

  -h, --help
      Show this help.

  --version
      Show version information.

Examples:
  ${SCRIPT_NAME} list

  ${SCRIPT_NAME} --backup add "0 3 * * * /home/user/bin/backup.sh"

  ${SCRIPT_NAME} --dry-run remove 4

Notes:
  Remove uses the line numbers shown by:
    ${SCRIPT_NAME} list

USAGE_END
}

error() {
    printf '%s\n' "ERROR: $*" >&2
}

info() {
    printf '%s\n' "INFO: $*"
}

cleanup() {
    [ -n "${TMPFILE:-}" ] && [ -f "$TMPFILE" ] && rm -f "$TMPFILE"
}

trap cleanup EXIT HUP INT TERM

is_positive_integer() {
    case "$1" in
        ''|*[!0-9]*)
            return 1
            ;;
        0)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

load_crontab() {
    # crontab -l exits non-zero when no crontab exists on many systems.
    # Treat that case as an empty crontab, but preserve other errors poorly
    # only as a warning because implementations differ.
    crontab -l 2>/dev/null || true
}

save_backup() {
    backup_dir="${HOME}/.local/share/cron-edit/backups"
    backup_file="${backup_dir}/crontab-$(date +%Y%m%d-%H%M%S).bak"

    mkdir -p "$backup_dir" || {
        error "Could not create backup directory: $backup_dir"
        exit 1
    }

    load_crontab > "$backup_file"

    info "Backup saved:"
    info "  $backup_file"
}

install_crontab() {
    if [ "$DRY_RUN" -eq 1 ]; then
        info "Dry run: resulting crontab would be:"
        printf '%s\n' "----------------------------------------"
        cat "$TMPFILE"
        printf '%s\n' "----------------------------------------"
        return 0
    fi

    if [ "$BACKUP" -eq 1 ]; then
        save_backup
    fi

    crontab "$TMPFILE" || {
        error "Failed to install new crontab."
        exit 1
    }
}

cmd_list() {
    if crontab -l >/dev/null 2>&1; then
        crontab -l | cat -n
    else
        info "No crontab installed for this user."
    fi
}

cmd_add() {
    job=$1

    TMPFILE=$(mktemp) || {
        error "Could not create temporary file."
        exit 1
    }

    load_crontab > "$TMPFILE"

    if [ "$FORCE" -ne 1 ] && grep -Fx -- "$job" "$TMPFILE" >/dev/null 2>&1; then
        error "Job already exists. Use --force to add a duplicate."
        exit 1
    fi

    # Ensure the existing crontab ends cleanly before appending.
    if [ -s "$TMPFILE" ]; then
        last_char=$(tail -c 1 "$TMPFILE" 2>/dev/null || printf '\n')
        [ "$last_char" = "$(printf '\n')" ] || printf '\n' >> "$TMPFILE"
    fi

    printf '%s\n' "$job" >> "$TMPFILE"

    install_crontab
    info "Cron job added."
}

cmd_remove() {
    line_number=$1

    if ! is_positive_integer "$line_number"; then
        error "LINE_NUMBER must be a positive integer."
        exit 2
    fi

    TMPFILE=$(mktemp) || {
        error "Could not create temporary file."
        exit 1
    }

    current=$(mktemp) || {
        error "Could not create temporary file."
        exit 1
    }

    load_crontab > "$current"

    line_count=$(wc -l < "$current" | tr -d ' ')

    if [ "$line_count" -eq 0 ]; then
        error "No crontab installed for this user."
        exit 1
    fi

    if [ "$line_number" -gt "$line_count" ]; then
        error "Line number $line_number does not exist. Current crontab has $line_count lines."
        exit 1
    fi

    sed "${line_number}d" "$current" > "$TMPFILE"

    rm -f "$current"

    install_crontab
    info "Cron line removed: $line_number"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --backup)
                BACKUP=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --force)
                FORCE=1
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
            add|list|remove)
                COMMAND=$1
                shift
                if [ "$#" -gt 0 ]; then
                    ARG=$1
                    shift
                fi
                if [ "$#" -gt 0 ]; then
                    error "Too many arguments."
                    usage >&2
                    exit 2
                fi
                return 0
                ;;
            *)
                error "Unknown option or command: $1"
                usage >&2
                exit 2
                ;;
        esac
    done
}

main() {
    parse_args "$@"

    if [ -z "$COMMAND" ]; then
        usage >&2
        exit 2
    fi

    case "$COMMAND" in
        add)
            if [ -z "$ARG" ]; then
                error "Missing cron-spec."
                usage >&2
                exit 2
            fi
            cmd_add "$ARG"
            ;;
        list)
            cmd_list
            ;;
        remove)
            if [ -z "$ARG" ]; then
                error "Missing LINE_NUMBER."
                usage >&2
                exit 2
            fi
            cmd_remove "$ARG"
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"