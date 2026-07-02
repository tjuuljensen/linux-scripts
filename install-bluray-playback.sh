#!/usr/bin/env bash
#
# install-bluray-playback.sh
#
# Fedora/Ubuntu Blu-ray playback helper for VLC/libbluray/libaacs.
#
# What it does:
#   - Installs VLC and Blu-ray support libraries on Fedora or Ubuntu/Debian.
#   - Optionally enables RPM Fusion on Fedora.
#   - Skips already installed packages.
#   - Downloads the FindVUK KEYDB.cfg database for AACS playback.
#   - Installs KEYDB.cfg only when missing, changed, or forced.
#   - Installs KEYDB.cfg for the invoking user.
#   - Optionally installs KEYDB.cfg system-wide at /etc/xdg/aacs/KEYDB.cfg.
#
# Legal note:
#   This script is for playing discs you are entitled to watch. AACS/BD+ use,
#   decryption keys, and DRM circumvention rules vary by jurisdiction.
#   Review local law before using the KEYDB download feature.
#
# Usage:
#   bash install-bluray-playback.sh
#   bash install-bluray-playback.sh --dry-run
#   bash install-bluray-playback.sh --verbose
#   bash install-bluray-playback.sh --no-keydb
#   bash install-bluray-playback.sh --force-keydb
#   bash install-bluray-playback.sh --system-keydb
#   bash install-bluray-playback.sh --fedora-no-rpmfusion
#   bash install-bluray-playback.sh --version
#   bash install-bluray-playback.sh --help

set -Eeuo pipefail

VERSION="0.4.1"

KEYDB_URL="http://fvonline-db.bplaced.net/fv_download.php?lang=eng"
INSTALL_KEYDB=1
FORCE_KEYDB=0
SYSTEM_KEYDB=0
ENABLE_RPMFUSION=1
DRY_RUN=0
VERBOSE=0

DOWNLOADED_KEYDB_FILE=""

declare -a BLURAY_HELPER_TEMP_DIRS=()

COLOR_RESET=""
COLOR_BLUE=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""

setup_colors() {
  if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    COLOR_RESET=$'\033[0m'
    COLOR_BLUE=$'\033[1;34m'
    COLOR_GREEN=$'\033[1;32m'
    COLOR_YELLOW=$'\033[1;33m'
    COLOR_RED=$'\033[1;31m'
  fi
}

log() {
  printf '%sinfo:%s %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*" >&2
}

warn() {
  printf '%swarn:%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
}

err() {
  printf '%serror:%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
}

die() {
  err "$*"
  exit 1
}

vlog() {
  if (( VERBOSE )); then
    log "$*"
  fi
}

usage() {
  cat <<'EOF'
install-bluray-playback.sh
Fedora/Ubuntu Blu-ray playback helper for VLC/libbluray/libaacs.

What it does:
  - Installs VLC and Blu-ray support libraries on Fedora or Ubuntu/Debian.
  - Optionally enables RPM Fusion on Fedora.
  - Skips already installed packages.
  - Downloads the FindVUK KEYDB.cfg database for AACS playback.
  - Installs KEYDB.cfg only when missing, changed, or forced.
  - Installs KEYDB.cfg for the invoking user.
  - Optionally installs KEYDB.cfg system-wide at /etc/xdg/aacs/KEYDB.cfg.

Legal note:
  This script is for playing discs you are entitled to watch. AACS/BD+ use,
  decryption keys, and DRM circumvention rules vary by jurisdiction.
  Review local law before using the KEYDB download feature.

Usage:
  bash install-bluray-playback.sh
  bash install-bluray-playback.sh --dry-run
  bash install-bluray-playback.sh --verbose
  bash install-bluray-playback.sh --no-keydb
  bash install-bluray-playback.sh --force-keydb
  bash install-bluray-playback.sh --system-keydb
  bash install-bluray-playback.sh --fedora-no-rpmfusion
  bash install-bluray-playback.sh --version
  bash install-bluray-playback.sh --help

Options:
  --dry-run
      Print the commands that would be run, but do not change the system.
      Dry-run automatically enables verbose output.

  --verbose
      Show skipped packages, KEYDB status, and detailed completion guidance.

  --no-keydb
      Install packages only. Do not download or install KEYDB.cfg.

  --force-keydb
      Reinstall KEYDB.cfg even if the installed file is identical.

  --system-keydb
      Also install KEYDB.cfg system-wide at /etc/xdg/aacs/KEYDB.cfg.
      This requires root/sudo.

  --fedora-no-rpmfusion
      Do not enable RPM Fusion automatically on Fedora.

  --keydb-url URL
      Override the KEYDB download URL.

  --version
      Print script version.

  -h, --help
      Show this help text.

After installation, test with:
  vlc bluray:///dev/sr0
EOF
}

print_cmd() {
  if [[ "${1:-}" == "sudo" ]]; then
    printf '+ sudo' >&2
    shift
  else
    printf '+' >&2
  fi

  local arg
  for arg in "$@"; do
    printf ' %q' "$arg" >&2
  done

  printf '\n' >&2
}

run() {
  if (( DRY_RUN )); then
    print_cmd "$@"
    return 0
  fi

  "$@"
}

run_priv() {
  if (( DRY_RUN )); then
    if (( EUID == 0 )); then
      print_cmd "$@"
    else
      print_cmd sudo "$@"
    fi
    return 0
  fi

  if (( EUID == 0 )); then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || die "sudo is required when not running as root."
    sudo "$@"
  fi
}

cleanup() {
  local d

  if (( ${#BLURAY_HELPER_TEMP_DIRS[@]} == 0 )); then
    return 0
  fi

  for d in "${BLURAY_HELPER_TEMP_DIRS[@]}"; do
    if [[ -n "${d:-}" && -d "$d" ]]; then
      rm -rf -- "$d" 2>/dev/null || true
    fi
  done
}

trap cleanup EXIT

make_temp_dir() {
  local d
  d="$(mktemp -d)"
  BLURAY_HELPER_TEMP_DIRS+=("$d")
  printf '%s\n' "$d"
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --version)
        printf '%s\n' "$VERSION"
        exit 0
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --verbose)
        VERBOSE=1
        shift
        ;;
      --no-keydb)
        INSTALL_KEYDB=0
        shift
        ;;
      --force-keydb)
        FORCE_KEYDB=1
        shift
        ;;
      --system-keydb)
        SYSTEM_KEYDB=1
        shift
        ;;
      --fedora-no-rpmfusion)
        ENABLE_RPMFUSION=0
        shift
        ;;
      --keydb-url)
        shift
        [[ $# -gt 0 ]] || die "--keydb-url requires a URL argument."
        KEYDB_URL="$1"
        shift
        ;;
      *)
        die "unknown option: $1. Use --help."
        ;;
    esac
  done
}

detect_os_family() {
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release."

  # shellcheck disable=SC1091
  . /etc/os-release

  local id="${ID:-}"
  local like="${ID_LIKE:-}"
  local combined=" ${id} ${like} "

  if [[ "$combined" == *" fedora "* || "$combined" == *" rhel "* ]]; then
    printf 'fedora\n'
    return 0
  fi

  if [[ "$combined" == *" ubuntu "* || "$combined" == *" debian "* ]]; then
    printf 'debian\n'
    return 0
  fi

  die "unsupported distribution: ID=${ID:-unknown}, ID_LIKE=${ID_LIKE:-unknown}. Fedora and Ubuntu/Debian are supported."
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

dnf_cmd() {
  if command -v dnf5 >/dev/null 2>&1; then
    printf 'dnf5\n'
    return 0
  fi

  if command -v dnf >/dev/null 2>&1; then
    printf 'dnf\n'
    return 0
  fi

  die "neither dnf5 nor dnf was found."
}

fedora_package_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

fedora_collect_missing() {
  local pkg
  local -n input_packages="$1"
  local -n output_missing="$2"

  output_missing=()

  for pkg in "${input_packages[@]}"; do
    if fedora_package_installed "$pkg"; then
      vlog "package already installed, skipping: $pkg"
    else
      output_missing+=("$pkg")
    fi
  done
}

install_fedora_rpmfusion_if_needed() {
  local dnf
  local fedora_version

  if (( ENABLE_RPMFUSION == 0 )); then
    vlog "RPM Fusion enablement disabled by --fedora-no-rpmfusion."
    return 0
  fi

  if rpm -q rpmfusion-free-release rpmfusion-nonfree-release >/dev/null 2>&1; then
    vlog "RPM Fusion free/nonfree already installed, skipping."
    return 0
  fi

  dnf="$(dnf_cmd)"
  fedora_version="$(rpm -E %fedora)"

  [[ -n "$fedora_version" && "$fedora_version" != "%fedora" ]] || die "could not determine Fedora release version."

  vlog "enabling RPM Fusion free/nonfree repositories."

  run_priv "$dnf" -y install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_version}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_version}.noarch.rpm"
}

install_fedora_packages() {
  local dnf
  local pkg

  dnf="$(dnf_cmd)"

  local -a core_packages=(
    vlc
    libbluray
    libaacs
    curl
    unzip
    ca-certificates
  )

  local -a optional_packages=(
    libbdplus
    libbluray-bdj
    java-latest-openjdk-headless
  )

  local -a missing_core=()
  local -a missing_optional=()

  fedora_collect_missing core_packages missing_core
  fedora_collect_missing optional_packages missing_optional

  if (( ${#missing_core[@]} == 0 && ${#missing_optional[@]} == 0 )); then
    vlog "all Fedora packages are already installed."
    return 0
  fi

  install_fedora_rpmfusion_if_needed

  if (( ${#missing_core[@]} > 0 )); then
    vlog "installing missing Fedora packages: ${missing_core[*]}"
    run_priv "$dnf" -y install "${missing_core[@]}"
  fi

  for pkg in "${missing_optional[@]}"; do
    vlog "installing missing optional Fedora package: $pkg"

    if ! run_priv "$dnf" -y install "$pkg"; then
      warn "optional package could not be installed: $pkg"
    fi
  done
}

debian_package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qx 'install ok installed'
}

debian_package_available() {
  apt-cache show "$1" >/dev/null 2>&1
}

debian_collect_missing() {
  local pkg
  local -n input_packages="$1"
  local -n output_missing="$2"

  output_missing=()

  for pkg in "${input_packages[@]}"; do
    if debian_package_installed "$pkg"; then
      vlog "package already installed, skipping: $pkg"
    else
      output_missing+=("$pkg")
    fi
  done
}

install_debian_packages() {
  local pkg

  local -a core_packages=(
    vlc
    libbluray2
    libaacs0
    curl
    unzip
    ca-certificates
  )

  local -a optional_packages=(
    libbdplus0
    libbluray-bdj
    default-jre-headless
  )

  local -a missing_core=()
  local -a missing_optional_candidates=()
  local -a missing_optional=()

  debian_collect_missing core_packages missing_core
  debian_collect_missing optional_packages missing_optional_candidates

  if (( ${#missing_core[@]} == 0 && ${#missing_optional_candidates[@]} == 0 )); then
    vlog "all Ubuntu/Debian packages are already installed."
    return 0
  fi

  vlog "updating apt package metadata."
  run_priv apt-get update

  if (( DRY_RUN )); then
    missing_optional=("${missing_optional_candidates[@]}")
  else
    for pkg in "${missing_optional_candidates[@]}"; do
      if debian_package_available "$pkg"; then
        missing_optional+=("$pkg")
      else
        vlog "optional package not available in configured apt repositories, skipping: $pkg"
      fi
    done
  fi

  if (( ${#missing_core[@]} > 0 )); then
    vlog "installing missing Ubuntu/Debian packages: ${missing_core[*]}"
    run_priv apt-get install -y "${missing_core[@]}"
  fi

  if (( ${#missing_optional[@]} > 0 )); then
    vlog "installing missing optional Ubuntu/Debian packages: ${missing_optional[*]}"
    run_priv apt-get install -y "${missing_optional[@]}"
  fi
}

install_packages() {
  local family
  family="$(detect_os_family)"

  case "$family" in
    fedora)
      install_fedora_packages
      ;;
    debian)
      install_debian_packages
      ;;
    *)
      die "internal error: unsupported OS family: $family"
      ;;
  esac
}

target_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
  else
    id -un
  fi
}

home_for_user() {
  local user="$1"
  local home

  home="$(getent passwd "$user" | awk -F: '{print $6}')"

  if [[ -z "$home" ]]; then
    die "could not determine home directory for user: $user"
  fi

  printf '%s\n' "$home"
}

user_keydb_path() {
  local user
  local home

  user="$(target_user)"
  home="$(home_for_user "$user")"

  printf '%s/.config/aacs/KEYDB.cfg\n' "$home"
}

download_keydb() {
  need_cmd curl
  need_cmd unzip

  local dir
  local download_file
  local extract_dir
  local keydb_file

  dir="$(make_temp_dir)"
  download_file="$dir/keydb-download"
  extract_dir="$dir/extracted"

  vlog "downloading KEYDB.cfg database from: $KEYDB_URL"

  run curl --fail --location --retry 3 --connect-timeout 20 --output "$download_file" "$KEYDB_URL"

  [[ -s "$download_file" ]] || die "downloaded KEYDB file is empty."

  if grep -qi '<html' "$download_file" 2>/dev/null; then
    die "downloaded file appears to be HTML, not a KEYDB archive/config. The KEYDB URL may have changed."
  fi

  if unzip -tq "$download_file" >/dev/null 2>&1; then
    vlog "extracting KEYDB.cfg."
    mkdir -p "$extract_dir"
    unzip -oq "$download_file" -d "$extract_dir"

    keydb_file="$(find "$extract_dir" -type f -iname 'KEYDB.cfg' -print -quit)"
    [[ -n "$keydb_file" ]] || die "archive did not contain KEYDB.cfg."
  else
    keydb_file="$download_file"
  fi

  [[ -s "$keydb_file" ]] || die "KEYDB.cfg is empty or missing."

  DOWNLOADED_KEYDB_FILE="$keydb_file"
}

install_user_keydb_file() {
  local keydb_file="$1"
  local user
  local home
  local group
  local dest_dir
  local dest_file

  user="$(target_user)"
  home="$(home_for_user "$user")"
  group="$(id -gn "$user")"

  dest_dir="$home/.config/aacs"
  dest_file="$dest_dir/KEYDB.cfg"

  vlog "installing KEYDB.cfg into: $dest_file"

  if (( EUID == 0 )); then
    install -d -m 0755 -o "$user" -g "$group" "$dest_dir"
    install -m 0644 -o "$user" -g "$group" "$keydb_file" "$dest_file"
  else
    mkdir -p "$dest_dir"
    install -m 0644 "$keydb_file" "$dest_file"
  fi
}

install_system_keydb_file() {
  local keydb_file="$1"

  vlog "installing system-wide KEYDB.cfg into: /etc/xdg/aacs/KEYDB.cfg"

  run_priv install -d -m 0755 /etc/xdg/aacs
  run_priv install -m 0644 "$keydb_file" /etc/xdg/aacs/KEYDB.cfg
}

install_keydb_if_changed() {
  local keydb_file="$1"
  local user_dest
  local system_dest

  user_dest="$(user_keydb_path)"

  if (( FORCE_KEYDB == 0 )) && [[ -f "$user_dest" ]] && cmp -s "$user_dest" "$keydb_file"; then
    vlog "KEYDB.cfg already current, skipping: $user_dest"
  else
    install_user_keydb_file "$keydb_file"
  fi

  if (( SYSTEM_KEYDB )); then
    system_dest="/etc/xdg/aacs/KEYDB.cfg"

    if (( FORCE_KEYDB == 0 )) && [[ -f "$system_dest" ]] && cmp -s "$system_dest" "$keydb_file"; then
      vlog "system KEYDB.cfg already current, skipping: $system_dest"
    else
      install_system_keydb_file "$keydb_file"
    fi
  fi
}

install_keydb() {
  if (( INSTALL_KEYDB == 0 )); then
    vlog "skipping KEYDB.cfg because --no-keydb was used."
    return 0
  fi

  if (( DRY_RUN )); then
    vlog "would download KEYDB.cfg from: $KEYDB_URL"
    vlog "would compare with installed KEYDB.cfg and only replace it if changed."

    local user_dest
    user_dest="$(user_keydb_path)"

    if [[ -f "$user_dest" ]]; then
      vlog "installed user KEYDB.cfg exists: $user_dest"
    else
      vlog "installed user KEYDB.cfg is missing: $user_dest"
    fi

    if (( SYSTEM_KEYDB )); then
      if [[ -f /etc/xdg/aacs/KEYDB.cfg ]]; then
        vlog "installed system KEYDB.cfg exists: /etc/xdg/aacs/KEYDB.cfg"
      else
        vlog "installed system KEYDB.cfg is missing: /etc/xdg/aacs/KEYDB.cfg"
      fi
    fi

    return 0
  fi

  download_keydb

  [[ -n "$DOWNLOADED_KEYDB_FILE" ]] || die "internal error: KEYDB download path was not set."

  install_keydb_if_changed "$DOWNLOADED_KEYDB_FILE"
}

finish() {
  if (( VERBOSE )); then
    printf '%sdone%s\n' "$COLOR_GREEN" "$COLOR_RESET"
    printf 'test: vlc bluray:///dev/sr0\n'
    printf 'vlc gui: Media -> Open Disc -> Blu-ray -> Play\n'
    printf 'note: some newer discs, UHD Blu-rays, region/drive issues, or missing keys may still fail.\n'
  else
    printf '%sdone%s\n' "$COLOR_GREEN" "$COLOR_RESET"
  fi
}

main() {
  setup_colors
  parse_args "$@"

  if (( DRY_RUN )); then
    VERBOSE=1
  fi

  vlog "install-bluray-playback version: $VERSION"

  install_packages
  install_keydb
  finish
}

main "$@"