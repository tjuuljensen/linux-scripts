#!/bin/sh
# simple script to edit cron from command line
# src: https://unix.stackexchange.com/questions/363376/how-do-i-add-remove-cron-jobs-by-script

usage () {
    cat <<USAGE_END
Usage:
    $0 add "job-spec"
    $0 list
    $0 remove "job-spec-lineno"
USAGE_END
}

if [ -z "$1" ]; then
    usage >&2
    exit 1
fi

case "$1" in
    add)
        if [ -z "$2" ]; then
            usage >&2
            exit 1
        fi

        tmpfile=$(mktemp)

        crontab -l >"$tmpfile"
        printf '%s\n' "$2" >>"$tmpfile"
        crontab "$tmpfile" && rm -f "$tmpfile"
        ;;
    list)
        crontab -l | cat -n
        ;;
    remove)
        if [ -z "$2" ]; then
            usage >&2
            exit 1
        fi

        tmpfile=$(mktemp)

        crontab -l | sed -e "$2d" >"$tmpfile"
        crontab "$tmpfile" && rm -f "$tmpfile"
        ;;
    *)
        usage >&2
        exit 1
esac
