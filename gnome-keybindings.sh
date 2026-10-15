#!/usr/bin/env bash
#
# gnome-keybindings.sh
#
# Purpose:
#   Back up and restore GNOME keyboard shortcuts, including custom shortcuts.
#
# Description:
#   Bash/jq counterpart of gnome-keybindings.py, using gsettings for all GNOME
#   access. Preserves GVariant values as strings and shares the Python JSON
#   export format. No Python runtime is required. TSV is not supported.
#
# Usage:
#   bash gnome-keybindings.sh --export keybindings.json
#   bash gnome-keybindings.sh --import keybindings.json --dry-run
#   bash gnome-keybindings.sh --import keybindings.json --preserve-custom-paths
#   bash gnome-keybindings.sh --export --normalize-disabled
#
# CLI behavior:
#   With no action, an existing filename implies import; otherwise export.
#   A filename of - (the default) uses stdin/stdout. --format json is accepted
#   for compatibility; --format tsv is rejected. --dry-run prints import
#   commands without setting values; it does not suppress an export.
#
# Custom shortcuts:
#   Imports renumber custom paths unless --preserve-custom-paths is supplied.
#   As in Python, --no-replace-custom skips the initial clearing operation;
#   the final path list still contains only the imported custom shortcuts.
#   It does not merge with existing shortcuts. With no custom items, the
#   existing custom-keybindings list is left alone.
#
# Requirements:
#   Bash 4+, jq 1.6+, gsettings, and standard Unix utilities.
#   Run imports as the intended desktop user in their GNOME session.
#
# Compatibility / errors:
#   Valid JSON exports are interchangeable with the Python version. Metadata
#   identifies this script and uses second-precision UTC timestamps. CLI help
#   layout and parser diagnostics differ. Malformed import items and NUL
#   characters are rejected before any settings are written. GSettings arrays
#   are parsed as data, never evaluated as shell commands or Python code.
#   Exit codes: 0 success, 1 runtime/import failure, 2 CLI error, 130 interrupt.
#
# Author:
#   Torsten Juul-Jensen
#
# Version:
#   1.0.0
#
# Date:
#   2026-10-15
#

set -o pipefail
export LC_ALL=C
VERSION=1.0.0
prog=${0##*/}
media_schema=org.gnome.settings-daemon.plugins.media-keys
custom_schema=$media_schema.custom-keybinding
action= filename=- have_filename=0 dry_run=0 preserve_paths=0 replace_custom=1 normalize_disabled=0
work_dir=
cleanup() { [[ -z $work_dir ]] || rm -rf -- "$work_dir"; }
trap cleanup EXIT
trap 'printf "Interrupted.\n" >&2; exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
usage() {
    printf 'usage: %s [-e | -i] [--format json] [--dry-run]\n' "$prog"
    printf '       [--preserve-custom-paths] [--no-replace-custom]\n'
    printf '       [--normalize-disabled] [--version] [filename]\n'
}
arg_error() { usage >&2; printf '%s: error: %s\n' "$prog" "$*" >&2; exit 2; }
help() {
    usage
    cat <<'HELP'

Import/export GNOME keyboard shortcuts using gsettings.

positional arguments:
  filename                 file to read/write; default is stdin/stdout (-)

options:
  -e, --export             export keybindings
  -i, --import             import keybindings
  --format json            export format; only JSON is supported
  --dry-run                show import commands without changing settings
  --preserve-custom-paths  reuse exported custom binding paths
  --no-replace-custom      skip clearing the custom path list before import
  --normalize-disabled    export ['disabled'] and [''] values as []
  --version               show version and exit
  -h, --help              show this help and exit

Examples:
  bash gnome-keybindings.sh --export ~/gnome-keybindings.json
  bash gnome-keybindings.sh --import ~/gnome-keybindings.json --dry-run
  bash gnome-keybindings.sh --import - --preserve-custom-paths

Without an action, an existing filename implies import; otherwise export.
JSON files are compatible with gnome-keybindings.py. TSV is not supported.
--no-replace-custom skips the initial clear, but the final custom path list
still contains only imported shortcuts; existing paths are not merged.
HELP
}
set_action() {
    [[ -z $action || $action == "$1" ]] || arg_error '--export and --import cannot be combined'
    action=$1
}
add_filename() {
    ((have_filename == 0)) || arg_error "unrecognized arguments: $1"
    filename=$1
    have_filename=1
}
options=(--export --import --format --dry-run --preserve-custom-paths --no-replace-custom --normalize-disabled --version --help)
while (($#)); do
    token=$1; shift
    if [[ $token == -- ]]; then
        for token in "$@"; do add_filename "$token"; done
        break
    fi
    option=${token%%=*}
    if [[ $option == --* ]]; then
        matches=()
        for candidate in "${options[@]}"; do
            if [[ $candidate == "$option" ]]; then matches=("$candidate"); break; fi
            [[ $candidate != "$option"* ]] || matches+=("$candidate")
        done
        ((${#matches[@]} <= 1)) || arg_error "ambiguous option: $option"
        ((${#matches[@]} == 0)) || option=${matches[0]}
    elif [[ $token == -[eih]* && ${#token} -gt 2 ]]; then
        for ((i=1; i<${#token}; i++)); do
            case ${token:i:1} in
                e) set_action export;; i) set_action import;; h) help; exit 0;;
                *) arg_error "unrecognized argument: $token";;
            esac
        done
        continue
    fi
    if [[ $token == *=* && $option != --format && $option == -* ]]; then
        arg_error "option $option does not take a value"
    fi
    case $option in
        -e|--export) set_action export;;
        -i|--import) set_action import;;
        --dry-run) dry_run=1;;
        --preserve-custom-paths) preserve_paths=1;;
        --no-replace-custom) replace_custom=0;;
        --normalize-disabled) normalize_disabled=1;;
        --version) printf '%s %s\n' "$prog" "$VERSION"; exit 0;;
        -h|--help) help; exit 0;;
        --format)
            if [[ $token == *=* ]]; then format=${token#*=}; else
                (($#)) && [[ $1 != -* ]] || arg_error 'argument --format: expected one argument'
                format=$1; shift
            fi
            [[ $format == json ]] || arg_error "unsupported format: $format (only json is supported; TSV is not supported)"
            ;;
        -) add_filename "$token";;
        -*)
            if [[ $token =~ ^-([0-9]+|[0-9]*\.[0-9]+)$ ]]; then add_filename "$token"
            else arg_error "unrecognized argument: $token"; fi;;
        *) add_filename "$token";;
    esac
done
command -v gsettings >/dev/null 2>&1 || die 'Required command not found: gsettings'
command -v jq >/dev/null 2>&1 || die 'Required command not found: jq'
if [[ -z $action ]]; then
    if [[ $filename != - && -e $filename ]]; then action=import; else action=export; fi
fi
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/gnome-keybindings.XXXXXXXX") || die 'Cannot create temporary directory.'

trim() {
    trimmed=${1#"${1%%[!$' \t\r\n\v\f']*}"}
    trimmed=${trimmed%"${trimmed##*[!$' \t\r\n\v\f']}"}
}
capture_gsettings() {
    if gsettings "$@" > "$work_dir/gsettings-out" 2> "$work_dir/gsettings-err"; then
        captured=$(cat "$work_dir/gsettings-out")
        return 0
    fi
    error_text=$(cat "$work_dir/gsettings-err")
    trim "$error_text"; error_text=$trimmed
    return 1
}
get_value() {
    if ! capture_gsettings get "$1" "$2"; then
        error_text="gsettings get $1 $2 failed: $error_text"
        return 1
    fi
    trim "$captured"; captured=$trimmed
}
shell_quote() {
    if [[ $1 =~ ^[a-zA-Z0-9_@%+=:,./-]+$ ]]; then printf '%s' "$1"
    else printf "'%s'" "${1//\'/\'\"\'\"\'}"; fi
}
set_value() {
    local schema=$1 key=$2 value=$3 arg
    if ((dry_run)); then
        printf 'DRY-RUN:'
        for arg in gsettings set "$schema" "$key" "$value"; do
            printf ' '; shell_quote "$arg"
        done
        printf '\n'
        return 0
    fi
    if ! capture_gsettings set "$schema" "$key" "$value"; then
        printf 'ERROR: failed to set %s %s: %s\n' "$schema" "$key" "$error_text" >&2
        return 1
    fi
}

# Parse the quoted string-array syntax printed by gsettings, including @as [],
# escaped quotes/backslashes and control/Unicode escapes. No eval is used.
cat > "$work_dir/strv.jq" <<'JQ' || die 'Cannot write temporary parser.'
def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
def hexnum:
  ascii_downcase | explode | reduce .[] as $c (0;
    . * 16 + (if $c >= 48 and $c <= 57 then $c - 48
              elif $c >= 97 and $c <= 102 then $c - 87
              else error("invalid hex escape") end));
def characters($quote; $out):
  if length == 0 then error("unterminated string")
  elif .[0:1] == $quote then {value: $out, rest: .[1:]}
  elif .[0:1] == "\\" then
    .[1:] as $tail | $tail[0:1] as $c |
    if $c == "u" or $c == "U" or $c == "x" then
      (if $c == "u" then 4 elif $c == "U" then 8 else 2 end) as $n |
      if ($tail | length) < $n + 1 then error("short Unicode escape") else
        ($tail[1:($n+1)] | hexnum) as $cp |
        if $cp == 0 or $cp > 1114111 or ($cp >= 55296 and $cp <= 57343)
        then error("invalid Unicode codepoint") else
          $tail[($n+1):] | characters($quote; $out + ([$cp] | implode))
        end
      end
    elif $c >= "0" and $c <= "7" then
      ($tail | capture("^(?<digits>[0-7]{1,3})").digits) as $digits |
      ($digits | explode | reduce .[] as $digit (0; . * 8 + $digit - 48)) as $cp |
      $tail[($digits | length):] | characters($quote; $out + ([$cp] | implode))
    elif $c == "" then error("unfinished escape")
    else
      ({"n":"\n", "r":"\r", "t":"\t", "b":"\b", "f":"\f",
        "v":"\u000b", "a":"\u0007", "\\":"\\", "'":"'", "\"":"\""}) as $escapes |
      $tail[1:] | characters($quote; $out + ($escapes[$c] // ("\\" + $c)))
    end
  else .[0:1] as $c | .[1:] | characters($quote; $out + $c)
  end;
def items($out):
  trim |
  if startswith("]") then {value: $out, rest: .[1:]}
  elif startswith("'") or startswith("\"") then
    .[0:1] as $quote | .[1:] | characters($quote; "") |
    .value as $value | .rest | trim |
    if startswith(",") then .[1:] | items($out + [$value])
    elif startswith("]") then {value: ($out + [$value]), rest: .[1:]}
    else error("expected comma or closing bracket") end
  else error("expected a quoted string") end;
trim | if startswith("@as ") then .[4:] | trim else . end |
if . == "" then []
elif startswith("[") then .[1:] | items([]) |
  if (.rest | trim) != "" then error("trailing array data") else .value end
else error("expected a string array") end |
if any(.[]; contains("\u0000")) then error("NUL is not supported") else . end
JQ

export_settings() {
    local fixed relocatable schema filter line rest path_or_schema key value path schema_path name command binding
    local -a schemas=(org.gnome.desktop.wm.keybindings org.gnome.settings-daemon.plugins.power "$media_schema")
    capture_gsettings list-schemas || die "gsettings list-schemas failed: $error_text"
    fixed=$captured
    if capture_gsettings list-relocatable-schemas; then relocatable=$captured; else relocatable=; fi
    [[ $'\n'$relocatable$'\n' == *$'\n'"$custom_schema"$'\n'* ]] || warn "relocatable schema not listed: $custom_schema"
    : > "$work_dir/items" || die 'Cannot write temporary export.'
    printf '[]\n' > "$work_dir/paths" || die 'Cannot write temporary path list.'
    for schema in "${schemas[@]}"; do
        if [[ $'\n'$fixed$'\n' != *$'\n'"$schema"$'\n'* ]]; then
            warn "schema not installed; skipping: $schema"
            continue
        fi
        capture_gsettings list-recursively "$schema" || continue
        # The Python script splits each output row on its first two spaces.
        while IFS= read -r line || [[ -n $line ]]; do
            [[ -n $line ]] || continue
            rest=${line#* }
            [[ $line == *' '* && $rest == *' '* ]] || die "Could not parse gsettings output line: $line"
            path_or_schema=${line%% *}; key=${rest%% *}; value=${rest#* }
            if [[ $schema == "$media_schema" && $key == custom-keybindings ]]; then
                printf '%s' "$value" | jq -Rs -f "$work_dir/strv.jq" > "$work_dir/paths" 2> "$work_dir/parse-error" ||
                    die "Could not parse GSettings string array: $value"
                continue
            fi
            [[ $schema != org.gnome.settings-daemon.plugins.power || $key == *button* ]] || continue
            trim "$value"
            [[ $trimmed == \[* || $trimmed == \'* ]] || continue
            if ((normalize_disabled)) && [[ $value == "['disabled']" || $value == "['']" ]]; then value='[]'; fi
            jq -cn --arg schema "$path_or_schema" --arg key "$key" --arg value "$value" \
                '{type:"setting",schema:$schema,key:$key,value:$value}' >> "$work_dir/items" || die 'Cannot build export item.'
        done <<< "$captured"
    done
    while IFS= read -r -d '' path; do
        schema_path=$custom_schema:$path
        if ! get_value "$schema_path" name; then warn "skipping custom binding $path: $error_text"; continue; fi
        name=$captured
        if ! get_value "$schema_path" command; then warn "skipping custom binding $path: $error_text"; continue; fi
        command=$captured
        if ! get_value "$schema_path" binding; then warn "skipping custom binding $path: $error_text"; continue; fi
        binding=$captured
        jq -cn --arg path "$path" --arg name "$name" --arg command "$command" --arg binding "$binding" \
            '{type:"custom",path:$path,name:$name,command:$command,binding:$binding}' >> "$work_dir/items" || die 'Cannot build custom export item.'
    done < <(jq -j '.[] | ., "\u0000"' "$work_dir/paths")
    jq -s --arg version "$VERSION" --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')" \
        '{format:"gnome-keybindings",format_version:1,tool:"gnome-keybindings.sh",
          tool_version:$version,exported_at:$timestamp,items:.}' "$work_dir/items" > "$work_dir/export" || die 'Cannot build JSON export.'
    if [[ $filename == - ]]; then cat "$work_dir/export"
    else cat "$work_dir/export" > "$filename" || die "Cannot write export file: $filename"; fi
}

load_fields() {
    fields=()
    local field
    while IFS= read -r -d '' field; do fields+=("$field"); done < <(printf '%s' "$1" | jq -j "($2) | ., \"\\u0000\"")
}
import_settings() {
    local item kind schema key value path name command binding schema_path escaped custom_list='[' separator= index=0 failures=0
    local -a fields custom_items=()
    if [[ $filename == - ]]; then cat > "$work_dir/input"
    else cat -- "$filename" > "$work_dir/input"; fi || die "Cannot read import file: $filename"
    if ! jq -e -Rs 'test("\\S")' "$work_dir/input" > /dev/null; then die 'Import file is empty.'; fi
    jq -s 'if length == 1 then .[0] else error("expected one JSON document") end' \
        "$work_dir/input" > "$work_dir/import" 2> "$work_dir/parse-error" ||
        die "invalid JSON import file (TSV is not supported): $(cat "$work_dir/parse-error")"
    jq -e 'type == "object" and .format == "gnome-keybindings"' "$work_dir/import" > /dev/null ||
        die 'JSON file is not a gnome-keybindings export.'
    jq -e '.items | type == "array"' "$work_dir/import" > /dev/null || die 'JSON import file has no items list.'
    # Validate the entire input before writing. Bash cannot represent NUL bytes.
    jq -e '
      def text: type == "string";
      all(.. | strings; (contains("\u0000") | not)) and
      all(.items[];
        type == "object" and
        (if .type == "setting" then ([.schema,.key,.value] | all(.[]; text))
         elif .type == "custom" then
           ([.name,.command,.binding] | all(.[]; text)) and
           (.path == null or (.path | text))
         else true end))
    ' "$work_dir/import" > /dev/null || die 'Invalid import item: expected string fields without NUL characters.'
    while IFS= read -r item; do
        kind=$(printf '%s' "$item" | jq -r '.type // "None"')
        case $kind in
            setting)
                load_fields "$item" '.schema,.key,.value'
                schema=${fields[0]}; key=${fields[1]}; value=${fields[2]}
                printf 'Importing %s %s\n' "$schema" "$key"
                set_value "$schema" "$key" "$value" || failures=$((failures+1))
                ;;
            custom) custom_items+=("$item");;
            *) warn "unknown item type skipped: $kind";;
        esac
    done < <(jq -c '.items[]' "$work_dir/import")
    if ((${#custom_items[@]})); then
        if ((replace_custom)); then
            printf 'Replacing custom keybinding path list.\n'
            set_value "$media_schema" custom-keybindings '[]' || failures=$((failures+1))
        fi
        for item in "${custom_items[@]}"; do
            load_fields "$item" '(.path // ""),.name,.command,.binding'
            path=${fields[0]}; name=${fields[1]}; command=${fields[2]}; binding=${fields[3]}
            if ((!preserve_paths)) || [[ -z $path ]]; then
                path=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom$index/
            fi
            index=$((index+1))
            escaped=${path//\\/\\\\}; escaped=${escaped//\'/\\\'}
            custom_list+="$separator'$escaped'"; separator=', '
            schema_path=$custom_schema:$path
            printf 'Installing custom keybinding: %s\n' "$name"
            set_value "$schema_path" name "$name" || failures=$((failures+1))
            set_value "$schema_path" command "$command" || failures=$((failures+1))
            set_value "$schema_path" binding "$binding" || failures=$((failures+1))
        done
        custom_list+=']'
        printf 'Importing list of custom keybindings.\n'
        set_value "$media_schema" custom-keybindings "$custom_list" || failures=$((failures+1))
    fi
    ((failures == 0))
}

if [[ $action == export ]]; then export_settings; else import_settings; fi
