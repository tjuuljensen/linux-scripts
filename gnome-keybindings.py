#!/usr/bin/env python3
"""
gnome-keybindings.py

Import/export GNOME keyboard shortcuts using gsettings.

Purpose:
  Back up and restore GNOME keyboard shortcuts, including custom shortcuts
  stored under org.gnome.settings-daemon.plugins.media-keys.custom-keybinding.

Data format:
  JSON is the default export format because it preserves quoting reliably.
  Legacy TSV import/export is also available for compatibility with older
  keybindings.pl style files.

Author:
  Torsten Juul-Jensen

Version:
  1.0.0

Date:
  2026-07-02
"""

from __future__ import annotations

import argparse
import ast
import datetime as _dt
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any

VERSION = "1.0.0"

MEDIA_KEYS_SCHEMA = "org.gnome.settings-daemon.plugins.media-keys"
CUSTOM_SCHEMA = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding"

EXPORT_SCHEMAS: list[tuple[str, str]] = [
    ("org.gnome.desktop.wm.keybindings", "."),
    ("org.gnome.settings-daemon.plugins.power", "button"),
    (MEDIA_KEYS_SCHEMA, "."),
]


class ScriptError(RuntimeError):
    """User-facing script error."""


def run_gsettings(args: list[str], *, capture: bool = True) -> subprocess.CompletedProcess[str]:
    cmd = ["gsettings", *args]
    return subprocess.run(
        cmd,
        check=False,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def shutil_which(command: str) -> str | None:
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory) / command
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def require_gsettings() -> None:
    if not shutil_which("gsettings"):
        raise ScriptError("Required command not found: gsettings")


def gsettings_stdout(args: list[str]) -> str:
    result = run_gsettings(args)
    if result.returncode != 0:
        stderr = (result.stderr or "").strip()
        raise ScriptError(f"gsettings {' '.join(args)} failed: {stderr}")
    return result.stdout or ""


def installed_schemas() -> set[str]:
    output = gsettings_stdout(["list-schemas"])
    return set(output.splitlines())


def installed_relocatable_schemas() -> set[str]:
    result = run_gsettings(["list-relocatable-schemas"])
    if result.returncode != 0:
        return set()
    return set((result.stdout or "").splitlines())


def parse_strv(value: str) -> list[str]:
    raw = value.strip()
    if raw.startswith("@as "):
        raw = raw[4:].strip()
    if raw in {"[]", ""}:
        return []

    try:
        parsed = ast.literal_eval(raw)
    except (ValueError, SyntaxError):
        raise ScriptError(f"Could not parse GSettings string array: {value!r}")

    if not isinstance(parsed, list) or not all(isinstance(item, str) for item in parsed):
        raise ScriptError(f"Expected a string array, got: {value!r}")

    return parsed


def quote_gvariant_string(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace("'", "\\'")
    return f"'{escaped}'"


def gvariant_strv(paths: list[str]) -> str:
    return "[" + ", ".join(quote_gvariant_string(path) for path in paths) + "]"


def looks_like_keybinding_value(value: str) -> bool:
    stripped = value.strip()
    return stripped.startswith("[") or stripped.startswith("'")


def list_recursively(schema: str) -> list[tuple[str, str, str]]:
    result = run_gsettings(["list-recursively", schema])
    if result.returncode != 0:
        return []

    rows: list[tuple[str, str, str]] = []
    for line in (result.stdout or "").splitlines():
        parts = line.split(" ", 2)
        if len(parts) != 3:
            raise ScriptError(f"Could not parse gsettings output line: {line!r}")
        path_or_schema, key, value = parts
        rows.append((path_or_schema, key, value))
    return rows


def get_value(schema_or_schema_path: str, key: str) -> str:
    return gsettings_stdout(["get", schema_or_schema_path, key]).strip()


def set_value(schema_or_schema_path: str, key: str, value: str, *, dry_run: bool) -> bool:
    cmd = ["gsettings", "set", schema_or_schema_path, key, value]

    if dry_run:
        print("DRY-RUN:", shlex.join(cmd))
        return True

    result = subprocess.run(cmd, check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    if result.returncode != 0:
        print(
            f"ERROR: failed to set {schema_or_schema_path} {key}: {(result.stderr or '').strip()}",
            file=sys.stderr,
        )
        return False

    return True


def export_settings(*, normalize_disabled: bool) -> dict[str, Any]:
    fixed_schemas = installed_schemas()
    relocatable_schemas = installed_relocatable_schemas()

    if CUSTOM_SCHEMA not in relocatable_schemas:
        print(f"WARN: relocatable schema not listed: {CUSTOM_SCHEMA}", file=sys.stderr)

    items: list[dict[str, Any]] = []
    custom_paths: list[str] = []

    for schema, key_filter in EXPORT_SCHEMAS:
        if schema not in fixed_schemas:
            print(f"WARN: schema not installed; skipping: {schema}", file=sys.stderr)
            continue

        for path_or_schema, key, value in list_recursively(schema):
            if schema == MEDIA_KEYS_SCHEMA and key == "custom-keybindings":
                custom_paths = parse_strv(value)
                continue

            if key_filter != "." and key_filter not in key:
                continue

            if not looks_like_keybinding_value(value):
                continue

            if normalize_disabled and value in {"['disabled']", "['']"}:
                value = "[]"

            items.append(
                {
                    "type": "setting",
                    "schema": path_or_schema,
                    "key": key,
                    "value": value,
                }
            )

    for custom_path in custom_paths:
        schema_path = f"{CUSTOM_SCHEMA}:{custom_path}"

        try:
            name = get_value(schema_path, "name")
            command = get_value(schema_path, "command")
            binding = get_value(schema_path, "binding")
        except ScriptError as exc:
            print(f"WARN: skipping custom binding {custom_path}: {exc}", file=sys.stderr)
            continue

        items.append(
            {
                "type": "custom",
                "path": custom_path,
                "name": name,
                "command": command,
                "binding": binding,
            }
        )

    return {
        "format": "gnome-keybindings",
        "format_version": 1,
        "tool": "gnome-keybindings.py",
        "tool_version": VERSION,
        "exported_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        "items": items,
    }


def write_json(data: dict[str, Any], filename: str) -> None:
    if filename == "-":
        json.dump(data, sys.stdout, indent=2, ensure_ascii=False)
        print()
        return

    path = Path(filename)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def write_tsv(data: dict[str, Any], filename: str) -> None:
    lines: list[str] = []

    for item in data["items"]:
        if item["type"] == "setting":
            lines.append(f"{item['schema']}\t{item['key']}\t{item['value']}")
        elif item["type"] == "custom":
            lines.append(f"custom\t{item['name']}\t{item['command']}\t{item['binding']}")

    output = "\n".join(lines) + ("\n" if lines else "")

    if filename == "-":
        sys.stdout.write(output)
    else:
        Path(filename).write_text(output, encoding="utf-8")


def read_import_file(filename: str) -> str:
    if filename == "-":
        return sys.stdin.read()

    return Path(filename).read_text(encoding="utf-8")


def load_import_data(filename: str) -> dict[str, Any]:
    text = read_import_file(filename)
    stripped = text.lstrip()

    if not stripped:
        raise ScriptError("Import file is empty.")

    if stripped.startswith("{"):
        data = json.loads(text)

        if data.get("format") != "gnome-keybindings":
            raise ScriptError("JSON file is not a gnome-keybindings export.")

        if "items" not in data or not isinstance(data["items"], list):
            raise ScriptError("JSON import file has no items list.")

        return data

    items: list[dict[str, Any]] = []

    for line_no, line in enumerate(text.splitlines(), start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue

        parts = line.split("\t")

        if parts[0] == "custom":
            if len(parts) != 4:
                raise ScriptError(f"Invalid custom TSV row at line {line_no}.")

            _, name, command, binding = parts

            items.append(
                {
                    "type": "custom",
                    "path": None,
                    "name": name,
                    "command": command,
                    "binding": binding,
                }
            )
        else:
            if len(parts) != 3:
                raise ScriptError(f"Invalid setting TSV row at line {line_no}.")

            schema, key, value = parts

            items.append(
                {
                    "type": "setting",
                    "schema": schema,
                    "key": key,
                    "value": value,
                }
            )

    return {
        "format": "gnome-keybindings",
        "format_version": 1,
        "tool": "legacy-tsv-import",
        "items": items,
    }


def import_settings(
    data: dict[str, Any],
    *,
    dry_run: bool,
    preserve_custom_paths: bool,
    replace_custom: bool,
) -> int:
    failures = 0
    custom_items: list[dict[str, Any]] = []

    for item in data["items"]:
        if item.get("type") == "setting":
            schema = item["schema"]
            key = item["key"]
            value = item["value"]

            print(f"Importing {schema} {key}")

            if not set_value(schema, key, value, dry_run=dry_run):
                failures += 1

        elif item.get("type") == "custom":
            custom_items.append(item)

        else:
            print(f"WARN: unknown item type skipped: {item.get('type')}", file=sys.stderr)

    if custom_items:
        custom_paths: list[str] = []

        if replace_custom:
            print("Replacing custom keybinding path list.")

            if not set_value(MEDIA_KEYS_SCHEMA, "custom-keybindings", "[]", dry_run=dry_run):
                failures += 1

        for index, item in enumerate(custom_items):
            if preserve_custom_paths and item.get("path"):
                custom_path = str(item["path"])
            else:
                custom_path = f"/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom{index}/"

            custom_paths.append(custom_path)
            schema_path = f"{CUSTOM_SCHEMA}:{custom_path}"

            name = item["name"]
            command = item["command"]
            binding = item["binding"]

            print(f"Installing custom keybinding: {name}")

            if not set_value(schema_path, "name", name, dry_run=dry_run):
                failures += 1

            if not set_value(schema_path, "command", command, dry_run=dry_run):
                failures += 1

            if not set_value(schema_path, "binding", binding, dry_run=dry_run):
                failures += 1

        custom_list_value = gvariant_strv(custom_paths)

        print("Importing list of custom keybindings.")

        if not set_value(MEDIA_KEYS_SCHEMA, "custom-keybindings", custom_list_value, dry_run=dry_run):
            failures += 1

    return failures


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Import/export GNOME keyboard shortcuts using gsettings.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Examples:
  gnome-keybindings.py --export ~/gnome-keybindings.json
  gnome-keybindings.py --import ~/gnome-keybindings.json
  gnome-keybindings.py --export --format tsv /tmp/keys.tsv
  gnome-keybindings.py --import /tmp/keys.tsv --dry-run

Notes:
  JSON is recommended. TSV import/export exists for compatibility with older
  keybindings.pl output, but JSON is safer for commands containing quotes.
""",
    )

    action = parser.add_mutually_exclusive_group()
    action.add_argument("-e", "--export", action="store_true", help="export keybindings")
    action.add_argument("-i", "--import", dest="do_import", action="store_true", help="import keybindings")

    parser.add_argument("filename", nargs="?", default="-", help="file to read/write; default is stdin/stdout")
    parser.add_argument("--format", choices=["json", "tsv"], default="json", help="export format; default: json")
    parser.add_argument("--dry-run", action="store_true", help="show gsettings set commands without changing settings")
    parser.add_argument("--preserve-custom-paths", action="store_true", help="reuse exported custom binding paths instead of renumbering")
    parser.add_argument("--no-replace-custom", action="store_true", help="do not clear the custom-keybindings list before import")
    parser.add_argument(
        "--normalize-disabled",
        action="store_true",
        help="export ['disabled'] and [''] shortcut values as [] like the original Perl script",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")

    return parser


def infer_action(args: argparse.Namespace) -> str:
    if args.do_import:
        return "import"

    if args.export:
        return "export"

    if args.filename != "-" and Path(args.filename).exists():
        return "import"

    return "export"


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        require_gsettings()
        action = infer_action(args)

        if action == "export":
            data = export_settings(normalize_disabled=args.normalize_disabled)

            if args.format == "json":
                write_json(data, args.filename)
            else:
                write_tsv(data, args.filename)

            return 0

        data = load_import_data(args.filename)

        failures = import_settings(
            data,
            dry_run=args.dry_run,
            preserve_custom_paths=args.preserve_custom_paths,
            replace_custom=not args.no_replace_custom,
        )

        return 1 if failures else 0

    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130

    except ScriptError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    except json.JSONDecodeError as exc:
        print(f"ERROR: invalid JSON import file: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())