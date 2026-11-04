#!/usr/bin/env bash
# build-akousma.sh: build Akousma on Linux.
#
# The dependencies come from the distribution's packages (apt, dnf, pacman, zypper); only Akousma itself is built
# (plus KDSingleApplication from source where the distribution's one is too old, e.g. Ubuntu 24.04). Outputs: an
# install folder, an AppImage (linuxdeploy) and a native package (.deb with Akousma's debian/, .rpm with its spec).
#
# Architectures: amd64, i386 and arm64 by default (ARCHS). This machine's one is built natively; each other one is
# built by this same script inside a container (podman or docker) of a distribution that has the packages for it:
# i386 on an amd64 machine without emulation, arm64 (or amd64 on an arm64 machine) with qemu-user via binfmt_misc.
#
# ./build-akousma.sh --help lists the options; linux/BUILD.txt describes them.
#
# Copyright (C) 2026 Genki (genki_jp0)
# License: GPL-3.0-or-later (see COPYING)

set -Eeuo pipefail
umask 022

readonly SCRIPT_NAME="build-akousma.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
readonly VERSIONS_DIR="${SCRIPT_DIR}/versions/linux"
readonly DEFAULT_SETTINGS_FILE="${SCRIPT_DIR}/build-settings.linux.conf"

# KDSingleApplication, built from source only when the distribution's package is missing or older than Akousma's
# minimum (CMakeLists.txt: find_package(KDSingleApplication-qt6 1.1.0 REQUIRED)). Ubuntu 24.04 has 1.0.0; upstream
# Strawberry's CI builds it from source there too (.github/workflows/build.yaml, "Build and install KDSingleApplication").
readonly KDSA_REPO="https://github.com/KDAB/KDSingleApplication.git"
readonly KDSA_REF_DEFAULT="v1.2.1"
readonly KDSA_MIN_VERSION="1.1.0"

# AppImage tools (downloaded into TOOLS_PATH when missing; --update-tools downloads them again).
readonly LINUXDEPLOY_URL="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-@ARCH@.AppImage"
readonly LINUXDEPLOY_QT_URL="https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-@ARCH@.AppImage"
readonly LINUXDEPLOY_GST_URL="https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gstreamer/master/linuxdeploy-plugin-gstreamer.sh"

# GStreamer plugins put into the AppImage: the list of upstream Strawberry's AppImage job (Akousma's
# .github/workflows/build.yaml, build-appimage, --gstreamer-plugin-list). Plugins that are not installed are left out
# (the run lists them).
readonly GST_PLUGINS="adaptivedemux2 aiff alsa apetag app asf asfmux audioconvert audiofx audioparsers audioresample
autodetect bs2b cdio coreelements dash dsd equalizer faac faad fdkaac flac gme hls icydemux id3demux isomp4 lame libav
matroska mpegtsdemux mpg123 musepack ogg openmpt opus pbtypes playback pulseaudio replaygain rtp rtpmanager rtsp soup
spectrum speex spotify taglib typefindfunctions udp volume vorbis wavenc wavpack wavparse xingmux"

# Architectures, by their Debian names (ARCHS, --arch): the name in folders and the AppImage ({ARCH}), the AppImage
# tools' name (linuxdeploy-<name>.AppImage), the container platform and the qemu-user name (qemu-<name>, binfmt_misc).
readonly DEFAULT_ARCHS="amd64,i386,arm64"
declare -A ARCH_DIR=([amd64]=x86_64 [i386]=i686 [arm64]=aarch64)
declare -A ARCH_TOOL=([amd64]=x86_64 [i386]=i386 [arm64]=aarch64)
declare -A ARCH_PLATFORM=([amd64]=linux/amd64 [i386]=linux/386 [arm64]=linux/arm64)
declare -A ARCH_QEMU=([amd64]=x86_64 [i386]=i386 [arm64]=aarch64)

# Container images of the other architectures: localhost/akousma-build:<arch>-<base image>, made from the base image
# by this script (--image-setup installs every package group). Raise IMAGE_RECIPE when that changes; an image is made
# again when its recipe (this number, the base image and the package lists) changes, or with --update-images.
readonly IMAGE_RECIPE=1
readonly IMAGE_REPO="localhost/akousma-build"
# The fallback base image: Debian 13 still builds Qt 6 (6.8) and every other package Akousma needs for i386, amd64 and
# arm64 (checked 2026-11; Ubuntu builds no i386 Qt 6 and has no i386 image, Fedora has no i686 image, Arch Linux's
# image is amd64 only).
readonly DEBIAN_IMAGE="docker.io/library/debian:trixie"

# ---------------------------------------------------------------------------------------------------------------------
# Distribution packages
#
# Sources for the names (checked 2026-11):
#   - Akousma's CMakeLists.txt (find_package / pkg_check_modules; REQUIRED ones and the optional components)
#   - apt:    Akousma's debian/control (Build-Depends and Depends) and the build-ubuntu / build-debian jobs of
#             .github/workflows/build.yaml (inherited from upstream Strawberry)
#   - dnf:    the build-fedora job of .github/workflows/build.yaml and dist/unix/akousma.spec.in (BuildRequires)
#   - zypper: the build-opensuse and build-appimage jobs of .github/workflows/build.yaml and the spec
#   - pacman: Arch Linux's strawberry PKGBUILD (gitlab.archlinux.org/archlinux/packaging/packages/strawberry, 1.2.31-2),
#             plus qt6-tools (lrelease), layer-shell-qt, gtest and sparsehash for the optional parts Akousma's CMake finds
#
# Groups: build (always), runtime (always: to run the install folder), tests (--tests), deb, rpm, appimage (when that
# output is made). An entry "a|b" takes the first one the package manager has; "name>=version:fallback" (apt only)
# uses the package only when its version is high enough, else the fallback: "kdsa" = build KDSingleApplication from
# source, "skip" = leave the optional feature out (LayerShellQt for Qt 6 is not in Ubuntu 24.04 / Debian 12).
# ---------------------------------------------------------------------------------------------------------------------
declare -A PKGS=()
PKGS[apt:build]="build-essential pkg-config git cmake ninja-build libglib2.0-dev libssl-dev libsqlite3-dev
libasound2-dev libpulse-dev libsecret-1-dev libtag-dev|libtag1-dev libicu-dev libuchardet-dev libxkbcommon-dev
qt6-base-dev qt6-base-private-dev qt6-base-dev-tools qt6-tools-dev qt6-tools-dev-tools qt6-l10n-tools
libkdsingleapplication-qt6-dev>=1.1.0:kdsa liblayershellqtinterface-dev>=6:skip libwayland-dev libgstreamer1.0-dev
libgstreamer-plugins-base1.0-dev libcdio-dev libgpod-dev libmtp-dev libchromaprint-dev libfftw3-dev libebur128-dev
libsparsehash-dev"
PKGS[apt:runtime]="libqt6sql6-sqlite qt6-qpa-plugins gstreamer1.0-plugins-base gstreamer1.0-plugins-good
gstreamer1.0-alsa gstreamer1.0-pulseaudio"
PKGS[apt:tests]="libgtest-dev libgmock-dev"
PKGS[apt:deb]="debhelper dpkg-dev fakeroot lsb-release"
PKGS[apt:appimage]="curl patchelf file desktop-file-utils gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav
libqt6svg6 qt6-wayland"

PKGS[dnf:build]="gcc-c++ make cmake ninja-build git pkgconf-pkg-config glib2-devel openssl-devel sqlite-devel alsa-lib-devel
pulseaudio-libs-devel libsecret-devel libicu-devel uchardet-devel libxkbcommon-devel qt6-qtbase-devel
qt6-qtbase-private-devel qt6-qttools-devel gstreamer1-devel gstreamer1-plugins-base-devel taglib-devel libcdio-devel
libgpod-devel libmtp-devel libchromaprint-devel libebur128-devel fftw-devel kdsingleapplication-qt6-devel
layer-shell-qt-devel wayland-devel sparsehash-devel"
PKGS[dnf:runtime]="qt6-qtbase-gui gstreamer1-plugins-base gstreamer1-plugins-good"
PKGS[dnf:tests]="gtest-devel gmock-devel"
PKGS[dnf:rpm]="rpm-build rpmdevtools lsb_release tar xz which desktop-file-utils libappstream-glib hicolor-icon-theme
gtest-devel gmock-devel"
PKGS[dnf:appimage]="curl patchelf file desktop-file-utils gstreamer1-plugins-bad-free gstreamer1-plugins-ugly-free gstreamer1-plugin-libav
qt6-qtsvg qt6-qtwayland"

PKGS[zypper:build]="gcc gcc-c++ make cmake ninja git pkg-config glibc-devel libopenssl-devel glib2-devel glib2-tools
alsa-devel sqlite3-devel libpulse-devel libsecret-devel gstreamer-devel gstreamer-plugins-base-devel taglib-devel
libicu-devel libuchardet-devel libcdio-devel libgpod-devel libmtp-devel libchromaprint-devel fftw3-devel
libebur128-devel qt6-core-devel qt6-gui-devel qt6-gui-private-devel qt6-widgets-devel qt6-concurrent-devel
qt6-network-devel qt6-sql-devel qt6-dbus-devel qt6-test-devel qt6-base-common-devel qt6-linguist-devel
sparsehash-devel kdsingleapplication-qt6-devel layer-shell-qt6-devel wayland-devel"
PKGS[zypper:runtime]="qt6-sql-sqlite gstreamer-plugins-base gstreamer-plugins-good"
PKGS[zypper:tests]="gtest gmock"
PKGS[zypper:rpm]="rpm-build lsb-release tar xz which desktop-file-utils update-desktop-files appstream-glib
hicolor-icon-theme gtest gmock"
PKGS[zypper:appimage]="curl patchelf file desktop-file-utils gstreamer-plugins-bad gstreamer-plugins-ugly gstreamer-plugins-libav
libQt6Svg6 qt6-wayland"

PKGS[pacman:build]="base-devel git cmake ninja pkgconf glib2 openssl sqlite alsa-lib libpulse libsecret taglib icu
uchardet qt6-base qt6-tools kdsingleapplication layer-shell-qt wayland gstreamer gst-plugins-base-libs libcdio libgpod
libmtp chromaprint fftw libebur128 sparsehash libx11 gdk-pixbuf2"
PKGS[pacman:runtime]="gst-plugins-base gst-plugins-good"
PKGS[pacman:tests]="gtest"
PKGS[pacman:appimage]="curl patchelf file desktop-file-utils gst-plugins-bad gst-plugins-ugly gst-libav qt6-svg qt6-wayland"

# ---------------------------------------------------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------------------------------------------------
if [[ -t 1 || "${AKOUSMA_BUILD_COLOR:-}" == 1 ]]; then
  C_STEP=$'\e[1;35m' C_WARN=$'\e[1;33m' C_ERR=$'\e[1;31m' C_OK=$'\e[1;32m' C_DIM=$'\e[2m' C_OFF=$'\e[0m'
else
  C_STEP="" C_WARN="" C_ERR="" C_OK="" C_DIM="" C_OFF=""
fi
step() { printf '\n%s==> %s%s\n' "$C_STEP" "$*" "$C_OFF"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '%s    %s%s\n' "$C_OK" "$*" "$C_OFF"; }
warn() { printf '%sWARNING: %s%s\n' "$C_WARN" "$*" "$C_OFF" >&2; }
die()  { printf '%sERROR: %s%s\n' "$C_ERR" "$*" "$C_OFF" >&2; exit 1; }

# Prints a command the way it can be copied into a shell.
quote_cmd() { local out="" a; for a in "$@"; do out+="$(printf '%q' "$a") "; done; printf '%s' "${out% }"; }

sha256_of() { sha256sum | cut -c1-64; }
sha256_file() { sha256sum "$1" | cut -c1-64; }

# Runs a long command with its output in <log dir>/<name>.log (and on the screen with --verbose). On failure: the end
# of the log and its path.
run_logged() {
  local name="$1"; shift
  local logfile="${LOG_DIR}/${name}.log"
  mkdir -p "$LOG_DIR"
  info "${C_DIM}\$ $(quote_cmd "$@")${C_OFF}"
  info "${C_DIM}log: ${logfile}${C_OFF}"
  { printf '### %s\n### %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(quote_cmd "$@")"; } > "$logfile"
  local rc=0
  if [[ "$OPT_VERBOSE" == 1 ]]; then
    "$@" 2>&1 | tee -a "$logfile" || rc=${PIPESTATUS[0]}
  elif [[ "${RUN_PROGRESS:-0}" == 1 ]]; then
    "$@" 2>&1 | tee -a "$logfile" | progress_filter || rc=${PIPESTATUS[0]}
  else
    "$@" >> "$logfile" 2>&1 || rc=$?
  fi
  if (( rc != 0 )); then
    printf '%s---- last lines of %s ----%s\n' "$C_ERR" "$logfile" "$C_OFF" >&2
    tail -n 40 "$logfile" >&2 || true
    die "${name} failed (exit ${rc}). Full log: ${logfile}"
  fi
}

# Shows the progress of a build (ninja "[n/m]", make "[ p%]") in steps of 10 %.
progress_filter() {
  awk '
    /^\[[0-9]+\/[0-9]+\]/ { split(substr($1, 2), a, "/"); if (a[2] + 0 > 0) show(int(a[1] * 100 / a[2])); next }
    /^\[ *[0-9]+%\]/ { s = $0; sub(/^\[ */, "", s); sub(/%.*/, "", s); show(s + 0) }
    function show(p) { if (p >= last + 10 || (p == 100 && last < 100)) { last = p - p % 10; if (p == 100) last = 100; printf "    %3d %%\n", p; fflush() } }
    BEGIN { last = -10 }'
}
progress() { RUN_PROGRESS=1 run_logged "$@"; }

# Runs a command as root: directly when we are root, else with sudo.
as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo "$@"
  else die "Needs root for: $(quote_cmd "$@") (sudo is not installed)."
  fi
}
root_prefix() { if [[ $EUID -eq 0 ]]; then printf ''; else printf 'sudo '; fi; }

usage() {
  cat <<'EOF'
Usage: ./build-akousma.sh [options]

Builds Akousma with the distribution's packages. Default: Akousma master from GitHub for amd64, i386 and arm64, each
built into an install folder and an AppImage, everything under ~/Atelier. Settings: build-settings.linux.conf next to
the script (created on the first run; an option on the command line wins for that run, --save-settings keeps it).

Architectures (default amd64,i386,arm64):
  --arch LIST             comma-separated: amd64, i386, arm64 (also x86_64, i686, aarch64). This machine's one is built
                          natively, the others in a container (podman or docker; arm64 on amd64 also needs qemu-user).
                          One that can't be built doesn't stop the others; the run then ends with an error.
  --container-engine E    podman, docker or auto (default: podman if it works, else docker)
  --container-image A=IMG base image for architecture A, repeatable (default: this distribution's release where it
                          has an image for A, else docker.io/library/debian:trixie)
  --container-arg ARG     extra argument for "<engine> run", repeatable
  --update-images         pull the base images and make the build images again (newest packages)

Akousma source:
  --repo URL              git URL (default https://github.com/Genki-jp0/Akousma.git), cloned to <src path>/akousma
  --ref REF               branch, tag or commit (default master). A branch is built at origin/<branch> after a fetch.
  --source DIR            a local checkout instead (built as it is, uncommitted changes included; not modified)
  --no-source             back to --repo/--ref (clears a saved --source)
  --release REL           build the commit recorded in versions/linux/REL.txt and compare the packages with it

Build:
  --build-type TYPE       release (default), debug or relwithdebinfo
  --jobs N                parallel jobs (default: number of CPUs)
  --werror / --no-werror  build with -Werror (default off)
  --tests / --no-tests    build and run Akousma's tests (default off; installs gtest/gmock)
  --cmake-arg ARG         extra CMake argument, repeatable (e.g. --cmake-arg -DENABLE_SPOTIFY=OFF)
  --clean                 delete the CMake build folder first (full rebuild)
  --force                 build and re-create the outputs even when nothing changed

Outputs (default install,appimage):
  --outputs LIST          comma-separated: install, appimage, deb, rpm, native (deb or rpm, by distribution); none
  --deb, --rpm, --native  add that package to the outputs
  --no-appimage           leave the AppImage out
  --update-tools          download the AppImage tools (linuxdeploy and plugins) again

Dependencies:
  --check-deps            show which packages are installed / missing (and the container setup), then stop
  --install-deps          install the missing packages (with sudo; the command is shown first), and podman and
                          qemu-user-static when the other architectures need them
  --yes                   with --install-deps: don't ask (passes -y / --noconfirm / -n)
  --freeze-deps REL       record the Akousma commit and each architecture's package versions in
                          versions/linux/REL.txt (after the build; with --dry-run without building). An existing file
                          is never replaced.

Folders (placeholders in the settings file: {WORK_ROOT} {PROJECT_ROOT} {DOWNLOADS_PATH} {BUILD_PATH} {ARCH}
{BUILD_TYPE}; {ARCH} is x86_64, i686 or aarch64):
  --work-root DIR         everything (default ~/Atelier)
  --project-root DIR      default {WORK_ROOT}/data/projects/akousma
  --downloads-path DIR    downloads (default {PROJECT_ROOT}/linux_/downloads)
  --src-path DIR          git clones: akousma, kdsingleapplication (default {DOWNLOADS_PATH})
  --build-path DIR        build tree (default {PROJECT_ROOT}/linux_/build_{ARCH}_{BUILD_TYPE})
  --prefix DIR            install folder (default {WORK_ROOT}/akousma_linux_{ARCH}_{BUILD_TYPE})
  --output-path DIR       AppImage / .deb / .rpm (default {BUILD_PATH}/packages)
  --tools-path DIR        linuxdeploy and its plugins (default {PROJECT_ROOT}/linux_/tools)
  --log-path FILE         the run log (default {PROJECT_ROOT}/build_linux.log); per step: <build path>/logs

Other:
  --settings FILE         another settings file (default build-settings.linux.conf next to the script)
  --save-settings         write the options given on this command line into the settings file
  --list                  show what would be built and why; builds nothing
  --dry-run               show the resolved settings, folders, source, packages and steps of each architecture;
                          changes nothing
  --verbose               show the build output (it is always in the step logs)
  -h, --help              this help
EOF
}

# ---------------------------------------------------------------------------------------------------------------------
# Settings: command line > settings file > defaults
# ---------------------------------------------------------------------------------------------------------------------
readonly SETTING_KEYS=(ARCHS WORK_ROOT PROJECT_ROOT DOWNLOADS_PATH SRC_PATH BUILD_PATH PREFIX_PATH OUTPUT_PATH TOOLS_PATH
  LOG_PATH AKOUSMA_REPO AKOUSMA_REF AKOUSMA_SOURCE BUILD_TYPE OUTPUTS JOBS WERROR TESTS CMAKE_ARGS CONTAINER_ENGINE
  CONTAINER_IMAGES CONTAINER_ARGS)
# shellcheck disable=SC2088 # "~" is kept in the file and expanded by expand_home
declare -A DEFAULTS=(
  [ARCHS]="$DEFAULT_ARCHS"
  [WORK_ROOT]="~/Atelier"
  [PROJECT_ROOT]="{WORK_ROOT}/data/projects/akousma"
  [DOWNLOADS_PATH]="{PROJECT_ROOT}/linux_/downloads"
  [SRC_PATH]="{DOWNLOADS_PATH}"
  [BUILD_PATH]="{PROJECT_ROOT}/linux_/build_{ARCH}_{BUILD_TYPE}"
  [PREFIX_PATH]="{WORK_ROOT}/akousma_linux_{ARCH}_{BUILD_TYPE}"
  [OUTPUT_PATH]="{BUILD_PATH}/packages"
  [TOOLS_PATH]="{PROJECT_ROOT}/linux_/tools"
  [LOG_PATH]="{PROJECT_ROOT}/build_linux.log"
  [AKOUSMA_REPO]="https://github.com/Genki-jp0/Akousma.git"
  [AKOUSMA_REF]="master"
  [AKOUSMA_SOURCE]=""
  [BUILD_TYPE]="release"
  [OUTPUTS]="install,appimage"
  [JOBS]=""
  [WERROR]="OFF"
  [TESTS]="OFF"
  [CMAKE_ARGS]=""
  [CONTAINER_ENGINE]="auto"
  [CONTAINER_IMAGES]=""
  [CONTAINER_ARGS]=""
)
declare -A SETTING_COMMENTS=(
  [ARCHS]="Architectures, comma-separated: amd64, i386, arm64 (this machine's natively, the others in a container)"
  [WORK_ROOT]="Everything goes under here unless a location below says otherwise"
  [PROJECT_ROOT]="Downloads, sources, build trees, the log"
  [DOWNLOADS_PATH]="Downloaded files"
  [SRC_PATH]="Git clones (akousma, kdsingleapplication); may be on another drive"
  [BUILD_PATH]="Build tree (CMake build folder, logs, stamps, AppDir, deb/rpm trees)"
  [PREFIX_PATH]="Install folder (bin/akousma, share/...)"
  [OUTPUT_PATH]="AppImage, .deb and .rpm files"
  [TOOLS_PATH]="linuxdeploy and its plugins"
  [LOG_PATH]="Log of each run (appended)"
  [AKOUSMA_REPO]="Akousma git repository"
  [AKOUSMA_REF]="Branch, tag or commit (a branch is built at origin/<branch>)"
  [AKOUSMA_SOURCE]="A local checkout to build instead of AKOUSMA_REPO/AKOUSMA_REF (empty: not used)"
  [BUILD_TYPE]="release, debug or relwithdebinfo"
  [OUTPUTS]="Comma-separated: install, appimage, deb, rpm, native"
  [JOBS]="Parallel jobs (empty: number of CPUs)"
  [WERROR]="ON: build with -Werror"
  [TESTS]="ON: build and run Akousma's tests"
  [CMAKE_ARGS]="Extra CMake arguments, separated by spaces (no quoting)"
  [CONTAINER_ENGINE]="Runs the other architectures' builds: podman, docker or auto (podman if it works, else docker)"
  [CONTAINER_IMAGES]="Base image per architecture, e.g. arm64=docker.io/library/debian:trixie (empty: see linux/BUILD.txt)"
  [CONTAINER_ARGS]="Extra arguments for '<engine> run', separated by spaces (no quoting)"
)
declare -A CLI=()     # settings given on the command line
declare -A FILESET=() # settings read from the file
declare -A RAW=()     # settings as given (placeholders kept), before they are resolved for an architecture
declare -A S=()       # resolved settings
SETTINGS_FILE="$DEFAULT_SETTINGS_FILE"
SETTINGS_NOTE=""

OPT_LIST=0 OPT_DRY_RUN=0 OPT_FORCE=0 OPT_CLEAN=0 OPT_VERBOSE=0 OPT_SAVE=0 OPT_CHECK_DEPS=0 OPT_INSTALL_DEPS=0
OPT_YES=0 OPT_UPDATE_TOOLS=0 OPT_FREEZE="" OPT_RELEASE="" OPT_UPDATE_IMAGES=0
CLI_CMAKE_ARGS=() CLI_CONTAINER_ARGS=() CLI_CONTAINER_IMAGES=()
# Internal (the run started by the user passes them to the run of each architecture): --arch-build ARCH builds that one
# architecture here, --host-arch the machine's architecture (a container doesn't know it), --pinned-commit the Akousma
# commit the first run resolved (so every architecture builds the same one), --image-setup installs the packages while
# a container image is made.
ARCH_BUILD="" HOST_ARCH_OPT="" OPT_PINNED="" OPT_IMAGE_SETUP=0
FWD_ARGS=()   # the options passed on to the run of each architecture
OUTPUT_ADD=() OUTPUT_REMOVE=()

# Reads a KEY=value file without running it: one setting per line, "#" comments, optional surrounding quotes.
# Prints "KEY<TAB>value" for valid lines; warns about others. $2: the keys allowed ("" = any [A-Za-z0-9_.+-] key).
read_kv_file() {
  local file="$1" allowed="${2:-}" line key value n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_.+-]+)[[:space:]]*=[[:space:]]*(.*[^[:space:]])?[[:space:]]*$ ]]; then
      key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]:-}"
      if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then value="${BASH_REMATCH[1]}"; fi
      if [[ -n "$allowed" && " $allowed " != *" $key "* ]]; then
        warn "${file}:${n}: unknown setting ${key} (ignored)"; continue
      fi
      printf '%s\t%s\n' "$key" "$value"
    else
      warn "${file}:${n}: not KEY=value (ignored): ${line}"
    fi
  done < "$file"
}

expand_home() {
  local p="$1"
  # shellcheck disable=SC2088 # a literal "~" from the settings file
  if [[ "$p" == "~" ]]; then p="$HOME"; elif [[ "$p" == "~/"* ]]; then p="${HOME}/${p#\~/}"; fi
  printf '%s' "$p"
}

# Expands the {PLACEHOLDERS} that are resolved so far, and ~.
expand_tokens() {
  local p="$1" k
  for k in WORK_ROOT PROJECT_ROOT DOWNLOADS_PATH BUILD_PATH ARCH BUILD_TYPE; do
    if [[ -n "${S[$k]:-}" ]]; then p="${p//\{$k\}/${S[$k]}}"; fi
  done
  p="$(expand_home "$p")"
  [[ "$p" == *"{"*"}"* ]] && die "Unresolved placeholder in '${1}' (placeholders only refer to the locations before them)."
  printf '%s' "$p"
}

abs_path() { # an absolute path without requiring it to exist
  local p; p="$(expand_home "$1")"
  [[ "$p" == /* ]] || p="${PWD}/${p}"
  realpath -m -- "$p"
}

load_settings() {
  local key value
  if [[ -f "$SETTINGS_FILE" ]]; then
    while IFS=$'\t' read -r key value; do FILESET[$key]="$value"; done \
      < <(read_kv_file "$SETTINGS_FILE" "${SETTING_KEYS[*]}")
    SETTINGS_NOTE="read"
  else
    SETTINGS_NOTE="not there yet"
  fi
  for key in "${SETTING_KEYS[@]}"; do
    if [[ -v "CLI[$key]" ]]; then S[$key]="${CLI[$key]}"
    elif [[ -v "FILESET[$key]" ]]; then S[$key]="${FILESET[$key]}"
    else S[$key]="${DEFAULTS[$key]}"
    fi
  done
  # Extra CMake arguments from the command line come after the ones in the file.
  if (( ${#CLI_CMAKE_ARGS[@]} )); then
    S[CMAKE_ARGS]="$(printf '%s ' "${S[CMAKE_ARGS]}" "${CLI_CMAKE_ARGS[@]}")"
    S[CMAKE_ARGS]="$(printf '%s' "${S[CMAKE_ARGS]}" | sed -e 's/^ *//' -e 's/ *$//')"
    CLI[CMAKE_ARGS]="${S[CMAKE_ARGS]}"
  fi
  # The same for the container arguments; a --container-image replaces that architecture's entry.
  if (( ${#CLI_CONTAINER_ARGS[@]} )); then
    S[CONTAINER_ARGS]="$(printf '%s ' "${S[CONTAINER_ARGS]}" "${CLI_CONTAINER_ARGS[@]}" | sed -e 's/^ *//' -e 's/ *$//')"
    CLI[CONTAINER_ARGS]="${S[CONTAINER_ARGS]}"
  fi
  local entry a value list=()
  if (( ${#CLI_CONTAINER_IMAGES[@]} )); then
    for entry in ${S[CONTAINER_IMAGES]//,/ }; do
      a="$(canonical_arch "${entry%%=*}" || printf '%s' "${entry%%=*}")"
      for value in "${CLI_CONTAINER_IMAGES[@]}"; do [[ "${value%%=*}" == "$a" ]] && continue 2; done
      list+=("$entry")
    done
    list+=("${CLI_CONTAINER_IMAGES[@]}")
    S[CONTAINER_IMAGES]="$(IFS=,; printf '%s' "${list[*]}")"
    CLI[CONTAINER_IMAGES]="${S[CONTAINER_IMAGES]}"
  fi
  for key in "${!S[@]}"; do RAW[$key]="${S[$key]}"; done
}

# The file is created with the defaults (placeholders kept, so changing WORK_ROOT moves everything that is still at
# its default). --save-settings updates the keys given on the command line, keeping the rest of the file as it is.
write_settings() {
  local tmp key line done_keys=" " value
  tmp="$(mktemp "${SETTINGS_FILE}.XXXXXX")"
  if [[ -f "$SETTINGS_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*= ]]; then
        key="${BASH_REMATCH[1]}"
        if [[ -v "CLI[$key]" ]]; then
          printf '%s=%s\n' "$key" "${CLI[$key]}" >> "$tmp"; done_keys+="$key "; continue
        fi
        done_keys+="$key "
      fi
      printf '%s\n' "$line" >> "$tmp"
    done < "$SETTINGS_FILE"
    for key in "${SETTING_KEYS[@]}"; do
      [[ "$done_keys" == *" $key "* ]] && continue
      value="${DEFAULTS[$key]}"; [[ -v "CLI[$key]" ]] && value="${CLI[$key]}"
      printf '\n# %s\n%s=%s\n' "${SETTING_COMMENTS[$key]}" "$key" "$value" >> "$tmp"
    done
  else
    {
      printf '# %s build settings: KEY=value, one per line. Created on the first run; yours to edit (not in git).\n' "$SCRIPT_NAME"
      printf '# An option on the command line wins for that run; --save-settings writes it here. Delete a line (or the\n'
      printf '# file) to get the default back. Locations may use {WORK_ROOT} {PROJECT_ROOT} {DOWNLOADS_PATH} {BUILD_PATH}\n'
      printf '# {ARCH} {BUILD_TYPE} (each only in the locations after it) and ~. The file is read, never run.\n'
      for key in "${SETTING_KEYS[@]}"; do
        value="${DEFAULTS[$key]}"; [[ "$OPT_SAVE" == 1 && -v "CLI[$key]" ]] && value="${CLI[$key]}"
        printf '\n# %s\n%s=%s\n' "${SETTING_COMMENTS[$key]}" "$key" "$value"
      done
    } > "$tmp"
  fi
  mv -f "$tmp" "$SETTINGS_FILE"
}

set_cli() { CLI[$1]="$2"; }
set_cli_path() { CLI[$1]="$(abs_path "$2")"; }

parse_args() {
  local opt val hasval fwd
  while (( $# )); do
    opt="$1"; val=""; hasval=0; fwd=1
    if [[ "$opt" == --*=* ]]; then val="${opt#*=}"; opt="${opt%%=*}"; set -- "$opt" "$val" "${@:2}"; fi
    case "$opt" in
      --repo|--ref|--source|--release|--build-type|--jobs|--cmake-arg|--outputs|--freeze-deps|--settings|\
      --work-root|--project-root|--downloads-path|--src-path|--build-path|--prefix|--output-path|--tools-path|--log-path|\
      --arch|--container-engine|--container-image|--container-arg|--arch-build|--host-arch|--pinned-commit)
        (( $# >= 2 )) || die "${opt} needs a value"
        val="$2"; hasval=1; shift 2 ;;
      *) shift ;;
    esac
    case "$opt" in
      --arch) parse_arch_list "$val"; set_cli ARCHS "$(IFS=,; printf '%s' "${ARCH_LIST[*]}")"; fwd=0 ;;
      --container-engine) set_cli CONTAINER_ENGINE "${val,,}" ;;
      --container-image)
        [[ "$val" == ?*=?* ]] || die "--container-image needs ARCH=IMAGE (e.g. arm64=docker.io/library/debian:trixie)"
        opt="$(canonical_arch "${val%%=*}")" || die "--container-image: unknown architecture '${val%%=*}'"
        CLI_CONTAINER_IMAGES+=("${opt}=${val#*=}"); opt=--container-image ;;
      --container-arg) CLI_CONTAINER_ARGS+=("$val") ;;
      --update-images) OPT_UPDATE_IMAGES=1; fwd=0 ;;
      --arch-build) ARCH_BUILD="$(canonical_arch "$val")" || die "--arch-build: unknown architecture '${val}'"; fwd=0 ;;
      --host-arch) HOST_ARCH_OPT="$val"; fwd=0 ;;
      --pinned-commit) [[ "$val" =~ ^[0-9a-f]{40}$ ]] || die "--pinned-commit needs a commit id"; OPT_PINNED="$val"; fwd=0 ;;
      --image-setup) OPT_IMAGE_SETUP=1; fwd=0 ;;
      --repo) set_cli AKOUSMA_REPO "$val" ;;
      --ref) set_cli AKOUSMA_REF "$val" ;;
      --source) [[ -n "$val" ]] || die "--source needs a folder (--no-source clears it)"; set_cli_path AKOUSMA_SOURCE "$val" ;;
      --no-source) set_cli AKOUSMA_SOURCE "" ;;
      --release) OPT_RELEASE="$val" ;;
      --build-type) set_cli BUILD_TYPE "${val,,}" ;;
      --jobs) [[ "$val" =~ ^[0-9]+$ && "$val" -gt 0 ]] || die "--jobs needs a number"; set_cli JOBS "$val" ;;
      --werror) set_cli WERROR ON ;;
      --no-werror) set_cli WERROR OFF ;;
      --tests) set_cli TESTS ON ;;
      --no-tests) set_cli TESTS OFF ;;
      --cmake-arg) CLI_CMAKE_ARGS+=("$val") ;;
      --clean) OPT_CLEAN=1 ;;
      --force) OPT_FORCE=1 ;;
      --outputs) set_cli OUTPUTS "$val" ;;
      --deb) OUTPUT_ADD+=(deb) ;;
      --rpm) OUTPUT_ADD+=(rpm) ;;
      --native) OUTPUT_ADD+=(native) ;;
      --appimage) OUTPUT_ADD+=(appimage) ;;
      --no-appimage) OUTPUT_REMOVE+=(appimage) ;;
      --update-tools) OPT_UPDATE_TOOLS=1 ;;
      --check-deps) OPT_CHECK_DEPS=1 ;;
      --install-deps) OPT_INSTALL_DEPS=1; fwd=0 ;;   # passed on to this machine's architecture only
      --yes|-y) OPT_YES=1 ;;
      --freeze-deps) OPT_FREEZE="$val" ;;
      --work-root) set_cli_path WORK_ROOT "$val" ;;
      --project-root) set_cli_path PROJECT_ROOT "$val" ;;
      --downloads-path) set_cli_path DOWNLOADS_PATH "$val" ;;
      --src-path) set_cli_path SRC_PATH "$val" ;;
      --build-path) set_cli_path BUILD_PATH "$val" ;;
      --prefix) set_cli_path PREFIX_PATH "$val" ;;
      --output-path) set_cli_path OUTPUT_PATH "$val" ;;
      --tools-path) set_cli_path TOOLS_PATH "$val" ;;
      --log-path) set_cli_path LOG_PATH "$val" ;;
      --settings) SETTINGS_FILE="$(abs_path "$val")"; fwd=0 ;;   # passed on as an absolute path
      --save-settings) OPT_SAVE=1; fwd=0 ;;
      --list) OPT_LIST=1 ;;
      --dry-run) OPT_DRY_RUN=1 ;;
      --verbose|-v) OPT_VERBOSE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: ${opt} (--help lists them)" ;;
    esac
    if (( fwd )); then
      # Paths go on absolute (the run of an architecture may start in another folder).
      case "$opt" in
        --source|--work-root|--project-root|--downloads-path|--src-path|--build-path|--prefix|--output-path|\
        --tools-path|--log-path) val="$(abs_path "$val")" ;;
      esac
      if (( hasval )); then FWD_ARGS+=("$opt" "$val"); else FWD_ARGS+=("$opt"); fi
    fi
  done
  for val in "$OPT_RELEASE" "$OPT_FREEZE"; do
    [[ -z "$val" || "$val" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || die "Not a release name: ${val}"
  done
}

# Resolves S (from the raw settings) for one architecture, $1 (amd64, i386, arm64).
resolve_settings() {
  local k raw
  ARCH_NAME="$1"
  S[ARCH]="${ARCH_DIR[$ARCH_NAME]}"
  TOOL_ARCH="${ARCH_TOOL[$ARCH_NAME]}"
  case "${S[BUILD_TYPE]}" in
    release) CMAKE_BUILD_TYPE=Release ;;
    debug) CMAKE_BUILD_TYPE=Debug ;;
    relwithdebinfo) CMAKE_BUILD_TYPE=RelWithDebInfo ;;
    *) die "BUILD_TYPE must be release, debug or relwithdebinfo (is '${S[BUILD_TYPE]}')" ;;
  esac
  for k in WERROR TESTS; do
    case "${S[$k]^^}" in ON|1|YES|TRUE) S[$k]=ON ;; OFF|0|NO|FALSE|"") S[$k]=OFF ;; *) die "${k} must be ON or OFF" ;; esac
  done
  if [[ -z "${S[JOBS]}" ]]; then S[JOBS]="$(nproc 2>/dev/null || echo 2)"; fi
  [[ "${S[JOBS]}" =~ ^[0-9]+$ ]] || die "JOBS must be a number"
  # Locations, in order: each one may use the ones before it.
  for k in WORK_ROOT PROJECT_ROOT DOWNLOADS_PATH SRC_PATH BUILD_PATH PREFIX_PATH OUTPUT_PATH TOOLS_PATH LOG_PATH; do
    raw="${RAW[$k]}"
    S[$k]="$(expand_tokens "$raw")"
    [[ -n "${S[$k]}" ]] || die "${k} is empty"
    S[$k]="$(abs_path "${S[$k]}")"
    # A build folder or install folder given without {ARCH} is this machine's architecture's; the other architectures
    # get _<arch> appended (unless the name says the architecture already), so they never build into the same folder.
    if [[ ( "$k" == BUILD_PATH || "$k" == PREFIX_PATH ) && "$raw" != *"{ARCH}"* && "$ARCH_NAME" != "$HOST_ARCH" ]]; then
      case "${S[$k]##*/}" in *"${S[ARCH]}"*|*"${ARCH_NAME}"*) ;; *) S[$k]+="_${S[ARCH]}" ;; esac
    fi
  done
  if [[ -n "${RAW[AKOUSMA_SOURCE]}" ]]; then S[AKOUSMA_SOURCE]="$(abs_path "$(expand_tokens "${RAW[AKOUSMA_SOURCE]}")")"; fi
  LOG_DIR="${S[BUILD_PATH]}/logs"
  STAMP_DIR="${S[BUILD_PATH]}/stamps"
  CMAKE_BUILD_DIR="${S[BUILD_PATH]}/akousma"
  DEPS_PREFIX="${S[BUILD_PATH]}/deps"
}

# ---------------------------------------------------------------------------------------------------------------------
# Distribution and packages
# ---------------------------------------------------------------------------------------------------------------------
declare -A OSR=()
detect_distro() {
  local key value f=/etc/os-release
  [[ -f "$f" ]] || f=/usr/lib/os-release
  if [[ -f "$f" ]]; then
    while IFS=$'\t' read -r key value; do OSR[$key]="$value"; done < <(read_kv_file "$f" "" 2>/dev/null)
  fi
  DISTRO_ID="${OSR[ID]:-unknown}"
  DISTRO_VERSION="${OSR[VERSION_ID]:-}"
  DISTRO_NAME="${OSR[PRETTY_NAME]:-$DISTRO_ID}"
  DISTRO_CODENAME="${OSR[VERSION_CODENAME]:-${OSR[UBUNTU_CODENAME]:-}}"
  local ids=" ${DISTRO_ID} ${OSR[ID_LIKE]:-} "
  PM=""
  case "$ids" in
    *" debian "*|*" ubuntu "*) PM=apt ;;
    *" fedora "*|*" rhel "*|*" centos "*) PM=dnf ;;
    *" arch "*|*" archlinux "*) PM=pacman ;;
    *" suse "*|*" opensuse "*|*" opensuse-tumbleweed "*|*" opensuse-leap "*) PM=zypper ;;
  esac
  if [[ -z "$PM" ]]; then
    if command -v apt-get >/dev/null 2>&1; then PM=apt
    elif command -v dnf >/dev/null 2>&1; then PM=dnf
    elif command -v pacman >/dev/null 2>&1; then PM=pacman
    elif command -v zypper >/dev/null 2>&1; then PM=zypper
    fi
  fi
  case "$PM" in
    apt) NATIVE_PKG=deb ;;
    dnf|zypper) NATIVE_PKG=rpm ;;
    *) NATIVE_PKG="" ;;
  esac
}

# "native" is the package format of the distribution the architecture is built on (in a container: the image's). A
# package this distribution can't make (.deb without apt, .rpm without dnf / zypper) is left out with a warning, so the
# other architectures still make it (e.g. --rpm on Fedora: no i386 .rpm, as there is no i686 Fedora).
resolve_outputs() {
  local list item out=() o
  SKIPPED_OUTPUTS=()
  list="${S[OUTPUTS]//,/ }"
  for item in $list "${OUTPUT_ADD[@]}"; do
    item="${item,,}"
    if [[ "$item" == native && -z "$NATIVE_PKG" ]]; then
      warn "${ARCH_NAME}: no native package format on ${DISTRO_NAME} (${PM:-no known package manager}): no package for ${ARCH_NAME}"
      SKIPPED_OUTPUTS+=(native); continue
    fi
    [[ "$item" == native ]] && item="$NATIVE_PKG"
    case "$item" in
      install|appimage|deb|rpm) ;;
      none) continue ;;
      *) die "Unknown output '${item}' (install, appimage, deb, rpm, native, none)" ;;
    esac
    for o in "${OUTPUT_REMOVE[@]}"; do [[ "$o" == "$item" ]] && continue 2; done
    [[ " ${out[*]} " == *" $item "* ]] || out+=("$item")
  done
  OUTPUTS=()
  for o in "${out[@]}"; do
    if [[ "$o" == deb && "$PM" != apt ]] || [[ "$o" == rpm && "$PM" != dnf && "$PM" != zypper ]]; then
      warn "${ARCH_NAME}: no .${o} (.deb packages are made on Debian / Ubuntu, .rpm on Fedora / openSUSE; ${ARCH_NAME} is built on ${DISTRO_NAME})"
      SKIPPED_OUTPUTS+=("$o"); continue
    fi
    OUTPUTS+=("$o")
  done
  return 0
}
has_output() { [[ " ${OUTPUTS[*]} " == *" $1 "* ]]; }

pkg_group() { # $1 = group: prints the entries of that group for this package manager
  # shellcheck disable=SC2086 # the lists are split into words on purpose
  printf '%s\n' ${PKGS[${PM}:${1}]:-}
}

wanted_groups() {
  WANTED_GROUPS=(build runtime)
  [[ "${S[TESTS]}" == ON ]] && WANTED_GROUPS+=(tests)
  has_output deb && WANTED_GROUPS+=(deb)
  has_output rpm && WANTED_GROUPS+=(rpm)
  has_output appimage && WANTED_GROUPS+=(appimage)
  return 0
}

pkg_installed_version() { # prints the installed version, or nothing
  local p="$1" out
  case "$PM" in
    apt)
      out="$(dpkg-query -W -f='${db:Status-Abbrev}|${Version}' "$p" 2>/dev/null || true)"
      [[ "$out" == ii* ]] && printf '%s' "${out#*|}" ;;
    dnf|zypper)
      out="$(rpm -q --qf '%{NAME} %{VERSION}-%{RELEASE}\n' --whatprovides "$p" 2>/dev/null | head -n1 || true)"
      [[ -n "$out" && "$out" != *"no package provides"* && "$out" != *"not installed"* ]] && printf '%s' "${out#* }" ;;
    pacman)
      out="$(pacman -Q "$p" 2>/dev/null | head -n1 || true)"
      [[ -n "$out" ]] && printf '%s' "${out#* }" ;;
  esac
  return 0
}

pkg_candidate_version() { # apt only: the version apt would install
  local out
  out="$(LC_ALL=C apt-cache policy "$1" 2>/dev/null | sed -n 's/^ *Candidate: *//p' | head -n1)"
  [[ -n "$out" && "$out" != "(none)" ]] && printf '%s' "$out"
  return 0
}

# Resolves the wanted groups into PKG_ROWS ("group|package|installed version|state") and the lists
# PKG_INSTALLED, PKG_MISSING; sets KDSA_FROM_SOURCE when KDSingleApplication has to be built.
resolve_packages() {
  local group entry name minver fallback alt ver cand chosen
  PKG_ROWS=() PKG_MISSING=() PKG_INSTALLED=() PKG_NOTES=()
  KDSA_FROM_SOURCE=0
  [[ -n "$PM" ]] || { PKG_NOTES+=("Unknown distribution (${DISTRO_NAME}): packages are not checked. Install the build dependencies yourself (see linux/BUILD.txt)."); return 0; }
  wanted_groups
  for group in "${WANTED_GROUPS[@]}"; do
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      name="$entry" minver="" fallback=""
      if [[ "$entry" == *">="* ]]; then
        name="${entry%%>=*}"; minver="${entry#*>=}"; fallback="${minver#*:}"; minver="${minver%%:*}"
      fi
      if [[ "$name" == *"|"* ]]; then
        chosen=""
        for alt in ${name//|/ }; do
          if [[ -n "$(pkg_installed_version "$alt")" ]]; then chosen="$alt"; break; fi
        done
        if [[ -z "$chosen" && "$PM" == apt ]]; then
          for alt in ${name//|/ }; do [[ -n "$(pkg_candidate_version "$alt")" ]] && { chosen="$alt"; break; }; done
        fi
        name="${chosen:-${name%%|*}}"
      fi
      ver="$(pkg_installed_version "$name")"
      if [[ -n "$minver" && "$PM" == apt ]]; then
        cand="$ver"; [[ -n "$cand" ]] || cand="$(pkg_candidate_version "$name")"
        if [[ -z "$cand" ]] || ! dpkg --compare-versions "$cand" ge "$minver"; then
          case "$fallback" in
            kdsa) KDSA_FROM_SOURCE=1
                  PKG_NOTES+=("${name} ${cand:-(not available)} is older than ${minver}: KDSingleApplication ${KDSA_REF} is built from source instead.") ;;
            *)    PKG_NOTES+=("${name} ${cand:-(not available)} is older than ${minver}: that optional feature is left out.") ;;
          esac
          PKG_ROWS+=("${group}|${name}|${ver}|not used")
          continue
        fi
      fi
      if [[ -n "$ver" ]]; then
        PKG_ROWS+=("${group}|${name}|${ver}|ok"); PKG_INSTALLED+=("$name")
      else
        PKG_ROWS+=("${group}|${name}||missing")
        [[ " ${PKG_MISSING[*]} " == *" $name "* ]] || PKG_MISSING+=("$name")
      fi
    done < <(pkg_group "$group")
  done
  return 0
}

# The version of an installed CMake package (from <name>ConfigVersion.cmake), or nothing.
cmake_package_version() {
  local d f
  for d in /usr/lib/cmake /usr/lib64/cmake /usr/lib/*-linux-gnu*/cmake /usr/local/lib/cmake /usr/local/lib64/cmake \
           /usr/share/cmake; do
    for f in "${d}/${1}/${1}ConfigVersion.cmake" "${d}/${1}/${1}-config-version.cmake"; do
      if [[ -f "$f" ]]; then sed -n 's/^ *set(PACKAGE_VERSION "\([^"]*\)").*/\1/p' "$f" | head -n1; return 0; fi
    done
  done
  return 0
}
kdsa_system_version() { cmake_package_version KDSingleApplication-qt6; }

qt_version() {
  local v q
  v="$(pkg-config --modversion Qt6Core 2>/dev/null || true)"
  if [[ -z "$v" ]] && q="$(find_qmake)"; then v="$("$q" -query QT_VERSION 2>/dev/null || true)"; fi
  printf '%s' "$v"
}

# Akousma's CMake stops when an optional feature that is on by default lacks its dependency
# (cmake/OptionalComponent.cmake), so the features this system can't have are switched off here, the way Akousma's
# debian/rules and spec do it for LayerShellQt. CMAKE_ARGS come later on the command line, so they can override these.
auto_cmake_args() {
  AUTO_CMAKE_ARGS=() AUTO_NOTES=()
  local lsq qv
  lsq="$(cmake_package_version LayerShellQt)"; qv="$(qt_version)"
  if [[ -z "$lsq" ]] || ! version_ge "$lsq" 6; then
    AUTO_CMAKE_ARGS+=(-DENABLE_LAYERSHELLQT=OFF); AUTO_NOTES+=("LayerShellQt for Qt 6 not installed${lsq:+ (found ${lsq})}: -DENABLE_LAYERSHELLQT=OFF")
  elif [[ -n "$qv" ]] && ! version_ge "$qv" 6.5; then
    AUTO_CMAKE_ARGS+=(-DENABLE_LAYERSHELLQT=OFF); AUTO_NOTES+=("Qt ${qv} has no QWaylandApplication (6.5+): -DENABLE_LAYERSHELLQT=OFF")
  fi
  return 0
}

version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

check_kdsa() {
  local v
  [[ "$KDSA_FROM_SOURCE" == 1 ]] && return 0
  [[ " ${PKG_MISSING[*]} " == *kdsingleapplication* ]] && return 0
  v="$(kdsa_system_version)"
  if [[ -n "$v" ]] && ! version_ge "$v" "$KDSA_MIN_VERSION"; then
    KDSA_FROM_SOURCE=1
    PKG_NOTES+=("KDSingleApplication-qt6 ${v} is older than ${KDSA_MIN_VERSION}: ${KDSA_REF} is built from source instead.")
  fi
  return 0
}

install_cmd() { # prints the install command as an array assignment into INSTALL_CMD
  INSTALL_CMD=()
  local y=()
  case "$PM" in
    apt)    [[ "$OPT_YES" == 1 ]] && y=(-y); INSTALL_CMD=(apt-get install "${y[@]}" --no-install-recommends "$@") ;;
    dnf)    [[ "$OPT_YES" == 1 ]] && y=(-y); INSTALL_CMD=(dnf install "${y[@]}" "$@") ;;
    zypper) [[ "$OPT_YES" == 1 ]] && y=(-n); INSTALL_CMD=(zypper "${y[@]}" install "$@") ;;
    pacman) [[ "$OPT_YES" == 1 ]] && y=(--noconfirm); INSTALL_CMD=(pacman -S --needed "${y[@]}" "$@") ;;
  esac
}

print_packages() {
  local row group name ver state last=""
  info "Distribution: ${DISTRO_NAME} (id ${DISTRO_ID} ${DISTRO_VERSION}), package manager: ${PM:-unknown}"
  for row in "${PKG_ROWS[@]}"; do
    IFS='|' read -r group name ver state <<< "$row"
    if [[ "$group" != "$last" ]]; then info "[${group}]"; last="$group"; fi
    case "$state" in
      ok) info "  ok       ${name} ${ver}" ;;
      missing) info "  ${C_WARN}MISSING${C_OFF}  ${name}" ;;
      *) info "  -        ${name} (${state})" ;;
    esac
  done
  local n; for n in "${PKG_NOTES[@]}"; do info "note: ${n}"; done
}

ensure_packages() {
  step "Packages (${WANTED_GROUPS[*]})"
  if [[ "$OPT_VERBOSE" == 1 || "$OPT_CHECK_DEPS" == 1 || "$OPT_DRY_RUN" == 1 ]]; then print_packages
  else
    info "Distribution: ${DISTRO_NAME}, package manager: ${PM:-unknown}; ${#PKG_INSTALLED[@]} installed, ${#PKG_MISSING[@]} missing"
    local n; for n in "${PKG_NOTES[@]}"; do info "note: ${n}"; done
  fi
  (( ${#PKG_MISSING[@]} )) || return 0
  install_cmd "${PKG_MISSING[@]}"
  local cmdline; cmdline="$(root_prefix)$(quote_cmd "${INSTALL_CMD[@]}")"
  if [[ "$OPT_INSTALL_DEPS" == 1 && "$OPT_DRY_RUN" == 0 && "$OPT_LIST" == 0 ]]; then
    info "Missing: ${PKG_MISSING[*]}"
    if [[ "$PM" == apt ]]; then
      info "Running: $(root_prefix)apt-get update"
      as_root apt-get update || die "apt-get update failed"
      # Again with the package lists just read: without them (a new system or container) apt knows no candidate
      # versions, so a "name>=version" entry would have been taken as too old.
      resolve_packages
      (( ${#PKG_MISSING[@]} )) || { ok "All packages installed."; return 0; }
      install_cmd "${PKG_MISSING[@]}"; cmdline="$(root_prefix)$(quote_cmd "${INSTALL_CMD[@]}")"
    fi
    info "Running: ${cmdline}"
    as_root "${INSTALL_CMD[@]}" || die "Installing the packages failed. The command was: ${cmdline}"
    resolve_packages
    (( ${#PKG_MISSING[@]} == 0 )) || die "Still missing after the install: ${PKG_MISSING[*]}"
    ok "All packages installed."
  else
    info "Missing: ${PKG_MISSING[*]}"
    info "Install them with:  ${cmdline}"
    info "or run this script with --install-deps."
    [[ "$OPT_CHECK_DEPS" == 1 || "$OPT_DRY_RUN" == 1 || "$OPT_LIST" == 1 ]] && return 0
    die "Missing packages (see above)."
  fi
}

# Versions of the dependency packages, "name=version" lines, sorted: for change detection and the release locks.
deps_snapshot() { # $@ = groups
  local row group name ver state g
  for row in "${PKG_ROWS[@]}"; do
    IFS='|' read -r group name ver state <<< "$row"
    for g in "$@"; do
      if [[ "$g" == "$group" && "$state" == ok ]]; then printf '%s=%s\n' "$name" "$ver"; fi
    done
  done | sort -u
  if [[ "$KDSA_FROM_SOURCE" == 1 ]]; then printf 'kdsingleapplication(source)=%s\n' "$KDSA_REF"; fi
}

# ---------------------------------------------------------------------------------------------------------------------
# Release locks (versions/linux/<release>.txt)
# ---------------------------------------------------------------------------------------------------------------------
# A lock has the keys every architecture shares (akousma_commit, build_tools_commit, frozen, archs) and one section per
# architecture, its keys prefixed with "<arch>." (amd64.distro=..., i386.pkg.libc6=...). LOCK is the view of this run's
# architecture: the shared keys plus its own section without the prefix. LOCK_HAS_ARCH: the lock records this one.
declare -A LOCK=()
LOCK_FILE="" LOCK_NAME="" LOCK_HAS_ARCH=0
load_lock() {
  local key value a
  declare -A all=()
  LOCK=()
  while IFS=$'\t' read -r key value; do all[$key]="$value"; done < <(read_kv_file "$1" "")
  [[ "${all[akousma_commit]:-}" =~ ^[0-9a-f]{40}$ ]] || die "${1}: no valid akousma_commit"
  LOCK_FILE="$1" LOCK_HAS_ARCH=0
  for key in "${!all[@]}"; do
    a="${key%%.*}"
    if [[ "$key" == *.* && -v "ARCH_DIR[$a]" ]]; then
      [[ "$a" == "${ARCH_NAME:-}" ]] && { LOCK[${key#*.}]="${all[$key]}"; LOCK_HAS_ARCH=1; }
    else
      LOCK[$key]="${all[$key]}"
    fi
  done
  # A lock of one architecture without sections (written before there were several): its arch= says which.
  if [[ ! -v "all[archs]" ]]; then
    a="$(canonical_arch "${all[arch]:-}" || true)"
    [[ -n "$a" && "$a" == "${ARCH_NAME:-}" ]] && LOCK_HAS_ARCH=1
  fi
  return 0
}

# A lock applies to --release REL, to --ref REL / vREL, and to a build of the commit a lock records.
find_lock() {
  local name f
  if [[ -n "$OPT_RELEASE" ]]; then
    f="${VERSIONS_DIR}/${OPT_RELEASE}.txt"
    [[ -f "$f" ]] || die "No lock for release ${OPT_RELEASE}: ${f} does not exist"
    load_lock "$f"; LOCK_NAME="$OPT_RELEASE"; return 0
  fi
  [[ -z "${S[AKOUSMA_SOURCE]}" ]] || return 0
  name="${S[AKOUSMA_REF]#v}"
  if [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && -f "${VERSIONS_DIR}/${name}.txt" ]]; then
    load_lock "${VERSIONS_DIR}/${name}.txt"; LOCK_NAME="$name"
  fi
  return 0
}
find_lock_by_commit() { # after the commit is known
  local f key value
  [[ -z "$LOCK_FILE" ]] || return 0
  for f in "${VERSIONS_DIR}"/*.txt; do
    [[ -f "$f" ]] || continue
    value="$(read_kv_file "$f" "" 2>/dev/null | awk -F'\t' '$1=="akousma_commit"{print $2}')"
    if [[ -n "$value" && "$value" == "${AKOUSMA_COMMIT:-}" ]]; then
      key="$(basename "$f" .txt)"; load_lock "$f"; LOCK_NAME="$key"; return 0
    fi
  done
  return 0
}

compare_lock() {
  [[ -n "$LOCK_FILE" ]] || return 0
  step "Release lock ${LOCK_NAME} (${LOCK_FILE})"
  if [[ "$LOCK_HAS_ARCH" == 0 ]]; then
    warn "The lock records no ${ARCH_NAME} build (it has: ${LOCK[archs]:-${LOCK[arch]:-?}}): building its commit ${LOCK[akousma_commit]:0:12}; the packages are not compared."
    return 0
  fi
  info "Akousma commit ${LOCK[akousma_commit]:0:12}, frozen ${LOCK[frozen]:-?} for ${ARCH_NAME} on ${LOCK[distro_name]:-?}${LOCK[container_image]:+ (container ${LOCK[container_image]})}"
  if [[ "${LOCK[distro]:-}" != "$DISTRO_ID" || "${LOCK[distro_version]:-}" != "$DISTRO_VERSION" ]]; then
    warn "The lock was made on ${LOCK[distro]:-?} ${LOCK[distro_version]:-?}, this is ${DISTRO_ID} ${DISTRO_VERSION}: the package versions can't match."
  fi
  local key name want have diffs=0 current
  declare -A NOW=()
  while IFS='=' read -r name have; do NOW[$name]="$have"; done < <(deps_snapshot build runtime tests deb rpm appimage)
  for key in "${!LOCK[@]}"; do
    [[ "$key" == pkg.* ]] || continue
    name="${key#pkg.}"; want="${LOCK[$key]}"; have="${NOW[$name]:-}"
    [[ "$name" == "kdsingleapplication(source)" ]] && continue
    if [[ -z "$have" ]]; then
      current="$(pkg_installed_version "$name")"
      [[ -n "$current" ]] && have="$current"
    fi
    if [[ "$have" != "$want" ]]; then
      diffs=$((diffs + 1))
      warn "package ${name}: ${have:-not installed} now, ${want} in the lock"
    fi
  done
  if (( diffs == 0 )); then ok "The installed packages are the versions in the lock."
  else
    warn "${diffs} package(s) differ from the lock. Distribution packages can't be pinned: the build uses what is installed (see linux/BUILD.txt, 'Release locks')."
  fi
}

# The run of an architecture writes its section of the lock to <build path>/stamps/freeze-<release>.part; the run the
# user started puts the sections of every architecture together (write_lock_file).
lock_part_file() { printf '%s/freeze-%s.part' "$STAMP_DIR" "$1"; }
write_lock_part() {
  local rel="$1" f
  f="$(lock_part_file "$rel")"
  mkdir -p "$STAMP_DIR"
  {
    printf 'distro=%s\n' "$DISTRO_ID"
    printf 'distro_version=%s\n' "$DISTRO_VERSION"
    printf 'distro_name=%s\n' "$DISTRO_NAME"
    printf 'package_manager=%s\n' "$PM"
    printf 'arch=%s\n' "$ARCH_NAME"
    printf 'build_type=%s\n' "${S[BUILD_TYPE]}"
    printf 'cmake_args=%s\n' "${S[CMAKE_ARGS]}"
    if [[ "$KDSA_FROM_SOURCE" == 1 ]]; then printf 'kdsingleapplication_ref=%s\n' "$KDSA_REF"; fi
    [[ -z "$KDSA_COMMIT" && "$KDSA_FROM_SOURCE" == 1 ]] && \
      KDSA_COMMIT="$(git -C "${S[SRC_PATH]}/kdsingleapplication" rev-parse -q --verify "${KDSA_REF}^{commit}" 2>/dev/null || true)"
    if [[ -n "$KDSA_COMMIT" ]]; then printf 'kdsingleapplication_commit=%s\n' "$KDSA_COMMIT"; fi
    if [[ -f "${S[TOOLS_PATH]}/linuxdeploy-${TOOL_ARCH}.AppImage" ]]; then
      printf 'tool.linuxdeploy.sha256=%s\n' "$(sha256_file "${S[TOOLS_PATH]}/linuxdeploy-${TOOL_ARCH}.AppImage")"
      [[ -f "${S[TOOLS_PATH]}/linuxdeploy-plugin-qt-${TOOL_ARCH}.AppImage" ]] && printf 'tool.linuxdeploy-plugin-qt.sha256=%s\n' "$(sha256_file "${S[TOOLS_PATH]}/linuxdeploy-plugin-qt-${TOOL_ARCH}.AppImage")"
    fi
    deps_snapshot build runtime tests deb rpm appimage | grep -v '^kdsingleapplication(source)=' | sed 's/^/pkg./'
  } > "${f}.tmp"
  mv -f "${f}.tmp" "$f"
}

# $1 = release, $2... = "arch|part file|container image" per architecture (image empty: built on this machine).
write_lock_file() {
  local rel="$1" f="${VERSIONS_DIR}/${1}.txt" tmp entry a part image archs=()
  shift
  if [[ -e "$f" ]]; then warn "${f} exists; not replaced (delete it first to freeze again)."; return 0; fi
  for entry; do archs+=("${entry%%|*}"); done
  mkdir -p "$VERSIONS_DIR"
  tmp="$(mktemp "${f}.XXXXXX")"
  {
    printf '# Akousma %s: what this release was built with (%s --freeze-deps %s).\n' "$rel" "$SCRIPT_NAME" "$rel"
    printf '# A build of this release (--release %s, --ref v%s or --ref <akousma_commit>) builds akousma_commit and\n' "$rel" "$rel"
    printf '# warns about each package whose installed version differs. Distribution packages are NOT pinned by this.\n'
    printf '# One section per architecture: <arch>.<key>.\n'
    printf 'akousma_commit=%s\n' "$AKOUSMA_COMMIT"
    printf 'akousma_source=%s\n' "$AKOUSMA_DESC"
    printf 'build_tools_commit=%s\n' "$(git -C "$SCRIPT_DIR" rev-parse -q --verify HEAD 2>/dev/null || echo unknown)"
    printf 'frozen=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'archs=%s\n' "$(IFS=,; printf '%s' "${archs[*]}")"
    for entry; do
      IFS='|' read -r a part image <<< "$entry"
      printf '\n# %s\n' "$a"
      if [[ -n "$image" ]]; then
        printf '%s.container_image=%s\n' "$a" "$image"
        printf '%s.container_image_digest=%s\n' "$a" "$(image_digest "$image")"
      fi
      sed "s/^/${a}./" "$part"
    done
  } > "$tmp"
  mv -f "$tmp" "$f"
  ok "Wrote ${f} (commit it to the build tools repository)."
}

# ---------------------------------------------------------------------------------------------------------------------
# Akousma source
# ---------------------------------------------------------------------------------------------------------------------
# Sets AKOUSMA_SRC (the tree CMake builds), AKOUSMA_COMMIT, AKOUSMA_ID (commit, or commit + hash of the local changes)
# and AKOUSMA_DESC. Nothing is changed with --dry-run / --list (the remote is asked with ls-remote instead).
resolve_akousma_source() {
  local src="${S[AKOUSMA_SOURCE]}"
  if [[ -n "$src" ]]; then
    [[ -f "${src}/CMakeLists.txt" ]] || die "--source ${src}: no CMakeLists.txt there"
    [[ -z "$OPT_RELEASE" ]] || die "--release builds the commit in the lock from git; it can't be combined with --source"
    [[ -v "CLI[AKOUSMA_REF]" ]] && warn "--ref is ignored: building the local checkout ${src}"
    AKOUSMA_SRC="$src"
    if git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
      AKOUSMA_COMMIT="$(git -C "$src" rev-parse HEAD)"
      local changes
      changes="$(cd "$src" && { git diff HEAD --binary 2>/dev/null || true
                    git ls-files -z --others --exclude-standard 2>/dev/null \
                      | xargs -0 -r sha256sum -- 2>/dev/null || true; } | sha256_of)"
      if [[ -z "$(git -C "$src" status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
        AKOUSMA_ID="$AKOUSMA_COMMIT"; AKOUSMA_DESC="local checkout ${src} at ${AKOUSMA_COMMIT:0:12} (clean)"
      else
        AKOUSMA_ID="${AKOUSMA_COMMIT}+local-${changes:0:12}"
        AKOUSMA_DESC="local checkout ${src} at ${AKOUSMA_COMMIT:0:12} with uncommitted changes (${changes:0:12})"
      fi
      AKOUSMA_IS_GIT=1
    else
      AKOUSMA_COMMIT=""
      AKOUSMA_ID="dir-$(cd "$src" && find . -path ./.git -prune -o -path ./build -prune -o -type f -printf '%P %s %T@\n' | sort | sha256_of | cut -c1-16)"
      AKOUSMA_DESC="folder ${src} (not a git checkout)"
      AKOUSMA_IS_GIT=0
    fi
    return 0
  fi

  AKOUSMA_SRC="${S[SRC_PATH]}/akousma"
  AKOUSMA_IS_GIT=1
  local repo="${S[AKOUSMA_REPO]}" ref="${S[AKOUSMA_REF]}" commit="" how=""
  if [[ -n "$LOCK_FILE" ]]; then
    ref="${LOCK[akousma_commit]}"; how="the commit in ${LOCK_FILE##*/}"
  fi
  local readonly_mode=0; [[ "$OPT_DRY_RUN" == 1 || "$OPT_LIST" == 1 ]] && readonly_mode=1

  if [[ ! -d "${AKOUSMA_SRC}/.git" ]]; then
    if (( readonly_mode )); then
      commit="${OPT_PINNED:-$(remote_commit "$repo" "$ref")}"
      AKOUSMA_COMMIT="${commit}"; AKOUSMA_ID="${commit:-unknown}"
      AKOUSMA_DESC="${repo} @ ${ref}${how:+ (${how})} = ${commit:-?} (not cloned yet: would clone to ${AKOUSMA_SRC})"
      return 0
    fi
    step "Cloning ${repo} to ${AKOUSMA_SRC}"
    mkdir -p "${S[SRC_PATH]}"
    run_logged git-clone git clone --no-checkout "$repo" "$AKOUSMA_SRC"
  fi

  local url; url="$(git -C "$AKOUSMA_SRC" remote get-url origin 2>/dev/null || true)"
  if [[ "$url" != "$repo" ]]; then
    if (( readonly_mode )); then
      info "The clone's origin is ${url}; would set it to ${repo}"
    else
      warn "The clone's origin was ${url:-none}; setting it to ${repo}"
      if [[ -n "$url" ]]; then git -C "$AKOUSMA_SRC" remote set-url origin "$repo"; else git -C "$AKOUSMA_SRC" remote add origin "$repo"; fi
    fi
  fi

  if [[ -n "$OPT_PINNED" ]] && { (( readonly_mode )) || git -C "$AKOUSMA_SRC" cat-file -e "${OPT_PINNED}^{commit}" 2>/dev/null; }; then
    # The commit the run started by the user resolved (and fetched) for every architecture.
    commit="$OPT_PINNED" REF_KIND="as resolved for all architectures"
  elif (( readonly_mode )); then
    # Without fetching: the remote's branch / tag as it is now, or a commit the clone already has.
    commit="$(remote_commit "$repo" "$ref")"
    [[ -n "$commit" ]] || commit="$(git -C "$AKOUSMA_SRC" rev-parse --verify -q "${ref}^{commit}" 2>/dev/null || true)"
  else
    step "Fetching ${repo}"
    run_logged git-fetch git -C "$AKOUSMA_SRC" fetch --prune --tags --force origin '+refs/heads/*:refs/remotes/origin/*'
    commit="$(resolve_ref_in_clone "$ref")"
    if [[ -z "$commit" && "$ref" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
      git -C "$AKOUSMA_SRC" fetch -q origin "$ref" 2>/dev/null && commit="$(git -C "$AKOUSMA_SRC" rev-parse --verify -q 'FETCH_HEAD^{commit}' || true)"
    fi
    [[ -n "$commit" ]] || die "Akousma ref '${ref}' not found in ${repo} (a branch, tag or commit)"
    [[ -z "$OPT_PINNED" ]] || commit="$OPT_PINNED"
  fi
  AKOUSMA_COMMIT="$commit"
  AKOUSMA_ID="${commit:-unknown}"
  AKOUSMA_DESC="${repo} @ ${ref}${how:+ (${how})} = ${commit:-?}${REF_KIND:+ (${REF_KIND})}"

  if [[ -n "$LOCK_FILE" && -z "$OPT_RELEASE" && "${S[AKOUSMA_REF]}" != "${LOCK[akousma_commit]}" && "$readonly_mode" == 0 ]]; then
    local tagc; tagc="$(resolve_ref_in_clone "${S[AKOUSMA_REF]}")"
    if [[ -n "$tagc" && "$tagc" != "${LOCK[akousma_commit]}" ]]; then
      warn "${S[AKOUSMA_REF]} is ${tagc:0:12} now, the lock records ${LOCK[akousma_commit]:0:12}: building the lock's commit."
    fi
  fi

  if (( ! readonly_mode )); then
    local head; head="$(git -C "$AKOUSMA_SRC" rev-parse -q --verify HEAD 2>/dev/null || true)"
    if [[ "$head" != "$commit" ]] || [[ -n "$(git -C "$AKOUSMA_SRC" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
      info "Checking out ${commit:0:12}"
      git -C "$AKOUSMA_SRC" -c advice.detachedHead=false checkout -q --force --detach "$commit"
    fi
    # Untracked files are removed; ignored ones (files Akousma's CMake generates in the source tree) are kept.
    git -C "$AKOUSMA_SRC" clean -q -fd
    git -C "$AKOUSMA_SRC" submodule -q update --init --recursive 2>/dev/null || true
  fi
}

# A branch is ALWAYS taken from origin/<branch> (the commit just fetched), never from a local branch of the same name,
# which could be stale. Then a tag, then any commit-ish.
REF_KIND=""
resolve_ref_in_clone() {
  local ref="$1" c
  REF_KIND=""
  if git -C "$AKOUSMA_SRC" show-ref --verify -q "refs/remotes/origin/${ref}"; then
    REF_KIND="branch origin/${ref}"; git -C "$AKOUSMA_SRC" rev-parse "refs/remotes/origin/${ref}^{commit}"; return 0
  fi
  if git -C "$AKOUSMA_SRC" show-ref --verify -q "refs/tags/${ref}"; then
    REF_KIND="tag ${ref}"; git -C "$AKOUSMA_SRC" rev-parse "refs/tags/${ref}^{commit}"; return 0
  fi
  c="$(git -C "$AKOUSMA_SRC" rev-parse --verify -q "${ref}^{commit}" 2>/dev/null || true)"
  [[ -n "$c" ]] && { REF_KIND="commit"; printf '%s\n' "$c"; }
  return 0
}

remote_commit() { # the commit a branch or tag names on the remote, without fetching (or the ref, if it is a sha)
  local repo="$1" ref="$2" out
  if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then printf '%s' "$ref"; return 0; fi
  out="$(timeout 30 git ls-remote "$repo" "refs/heads/${ref}" "refs/tags/${ref}^{}" "refs/tags/${ref}" 2>/dev/null || true)"
  printf '%s\n' "$out" | awk -v h="refs/heads/${ref}" -v p="refs/tags/${ref}^{}" -v t="refs/tags/${ref}" '
    $2==h{b=$1} $2==p{d=$1} $2==t{g=$1} END{ if(b)print b; else if(d)print d; else if(g)print g }'
}

# ---------------------------------------------------------------------------------------------------------------------
# KDSingleApplication from source (only when needed)
# ---------------------------------------------------------------------------------------------------------------------
KDSA_REF="$KDSA_REF_DEFAULT" KDSA_COMMIT=""
build_kdsa() {
  [[ "$KDSA_FROM_SOURCE" == 1 ]] || return 0
  local src="${S[SRC_PATH]}/kdsingleapplication" bdir="${S[BUILD_PATH]}/kdsingleapplication" stamp want
  step "KDSingleApplication ${KDSA_REF} from source (into ${DEPS_PREFIX})"
  if [[ ! -d "${src}/.git" ]]; then
    mkdir -p "${S[SRC_PATH]}"
    run_logged kdsa-clone git clone "$KDSA_REPO" "$src"
  fi
  if ! git -C "$src" rev-parse -q --verify "${KDSA_REF}^{commit}" >/dev/null 2>&1; then
    run_logged kdsa-fetch git -C "$src" fetch --tags --force origin
  fi
  KDSA_COMMIT="$(git -C "$src" rev-parse "${KDSA_REF}^{commit}")" || die "KDSingleApplication ref ${KDSA_REF} not found"
  want="commit=${KDSA_COMMIT} qt=$(pkg_installed_version "$(qt_base_package)")"
  stamp="${STAMP_DIR}/kdsingleapplication.stamp"
  if [[ -f "$stamp" && "$(cat "$stamp")" == "$want" && -d "${DEPS_PREFIX}" && "$OPT_FORCE" == 0 ]]; then
    info "skip: ${KDSA_REF} (${KDSA_COMMIT:0:12}) is built"; return 0
  fi
  git -C "$src" -c advice.detachedHead=false checkout -q --force --detach "$KDSA_COMMIT"
  git -C "$src" submodule -q update --init --recursive
  rm -rf "$bdir"
  # Static, as upstream Strawberry's CI does it on Ubuntu 24.04, so neither the install folder nor the packages
  # need a KDSingleApplication library at run time.
  run_logged kdsa-configure cmake -S "$src" -B "$bdir" "${GENERATOR_ARGS[@]}" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" -DKDSingleApplication_QT6=ON -DKDSingleApplication_STATIC=ON \
    -DBUILD_SHARED_LIBS=OFF -DKDSingleApplication_EXAMPLES=OFF -DKDSingleApplication_TESTS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  progress kdsa-build cmake --build "$bdir" -j "${S[JOBS]}"
  rm -rf "$DEPS_PREFIX"
  run_logged kdsa-install cmake --install "$bdir"
  mkdir -p "$STAMP_DIR"; printf '%s' "$want" > "$stamp"
  ok "KDSingleApplication ${KDSA_REF} installed in ${DEPS_PREFIX}"
}
qt_base_package() { # the Qt base development package of this distribution, for the KDSingleApplication stamp
  case "$PM" in apt) echo qt6-base-dev ;; dnf) echo qt6-qtbase-devel ;; zypper) echo qt6-core-devel ;; pacman) echo qt6-base ;; *) echo qt6 ;; esac
}

# ---------------------------------------------------------------------------------------------------------------------
# Change detection
# ---------------------------------------------------------------------------------------------------------------------
# Stamps (KEY=value) in <build path>/stamps: build.stamp for the CMake build, <output>.stamp for each output.
stamp_get() { local f="$1" k="$2"; [[ -f "$f" ]] && awk -v k="$k" 'index($0, k"=")==1 { print substr($0, length(k)+2); exit }' "$f"; return 0; }

compute_config() {
  CMAKE_ARGS_ARR=()
  if [[ -n "${S[CMAKE_ARGS]}" ]]; then read -r -a CMAKE_ARGS_ARR <<< "${S[CMAKE_ARGS]}"; fi
  if command -v ninja >/dev/null 2>&1 || command -v ninja-build >/dev/null 2>&1; then GENERATOR_ARGS=(-G Ninja); GENERATOR=Ninja
  else GENERATOR_ARGS=(-G "Unix Makefiles"); GENERATOR="Unix Makefiles"; fi
  CONFIGURE_ARGS=(-DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" -DCMAKE_INSTALL_PREFIX="${S[PREFIX_PATH]}"
    -DBUILD_WERROR="${S[WERROR]}")
  [[ "$KDSA_FROM_SOURCE" == 1 ]] && CONFIGURE_ARGS+=(-DCMAKE_PREFIX_PATH="$DEPS_PREFIX")
  auto_cmake_args
  CONFIGURE_ARGS+=("${AUTO_CMAKE_ARGS[@]}" "${CMAKE_ARGS_ARR[@]}")
  CONFIG_TEXT="source=${AKOUSMA_SRC} generator=${GENERATOR} $(printf '%s ' "${CONFIGURE_ARGS[@]}")tests=${S[TESTS]} kdsa=${KDSA_FROM_SOURCE}:${KDSA_REF}"
  CONFIG_HASH="$(printf '%s' "$CONFIG_TEXT" | sha256_of | cut -c1-16)"
  DEPS_TEXT="$(deps_snapshot build runtime tests)"
  DEPS_HASH="$(printf '%s' "$DEPS_TEXT" | sha256_of | cut -c1-16)"
  BUILD_ID="akousma=${AKOUSMA_ID} config=${CONFIG_HASH} deps=${DEPS_HASH}"
}

# Decides what to do. BUILD_NEEDED=1/0 with BUILD_REASONS; per output: OUT_NEEDED[o] and OUT_REASON[o].
declare -A OUT_NEEDED=() OUT_REASON=()
detect_changes() {
  local f="${STAMP_DIR}/build.stamp" old
  BUILD_REASONS=()
  if [[ "$OPT_CLEAN" == 1 ]]; then BUILD_REASONS+=("--clean: full rebuild")
  elif [[ ! -f "${CMAKE_BUILD_DIR}/CMakeCache.txt" || ! -x "${CMAKE_BUILD_DIR}/akousma" ]]; then BUILD_REASONS+=("no build yet in ${CMAKE_BUILD_DIR}")
  elif [[ ! -f "$f" ]]; then BUILD_REASONS+=("no stamp (an unfinished or older build)")
  else
    old="$(stamp_get "$f" akousma)"
    [[ "$old" == "$AKOUSMA_ID" ]] || BUILD_REASONS+=("akousma changed $(short_id "$old") -> $(short_id "$AKOUSMA_ID")")
    old="$(stamp_get "$f" config)"
    [[ "$old" == "$CONFIG_HASH" ]] || BUILD_REASONS+=("settings changed: $(diff_words "$(stamp_get "$f" config_text)" "$CONFIG_TEXT")")
    old="$(stamp_get "$f" deps)"
    if [[ "$old" != "$DEPS_HASH" ]]; then
      BUILD_REASONS+=("packages changed: $(diff_deps "${STAMP_DIR}/build.deps" "$DEPS_TEXT")")
    fi
  fi
  if (( ${#BUILD_REASONS[@]} == 0 )) && [[ "$OPT_FORCE" == 1 ]]; then BUILD_REASONS+=("--force"); fi
  BUILD_NEEDED=0; (( ${#BUILD_REASONS[@]} )) && BUILD_NEEDED=1
  local o
  for o in "${OUTPUTS[@]}"; do
    f="${STAMP_DIR}/${o}.stamp"
    if [[ "$OPT_FORCE" == 1 ]]; then OUT_NEEDED[$o]=1; OUT_REASON[$o]="--force"
    elif [[ "$OPT_UPDATE_TOOLS" == 1 && "$o" == appimage ]]; then OUT_NEEDED[$o]=1; OUT_REASON[$o]="--update-tools"
    elif [[ ! -f "$f" ]]; then OUT_NEEDED[$o]=1; OUT_REASON[$o]="not made yet"
    elif [[ "$(stamp_get "$f" build)" != "$BUILD_ID" ]]; then OUT_NEEDED[$o]=1; OUT_REASON[$o]="the build changed"
    elif [[ "$(stamp_get "$f" extra)" != "$(output_extra "$o")" ]]; then OUT_NEEDED[$o]=1; OUT_REASON[$o]="its settings or tools changed"
    elif ! output_present "$o" "$(stamp_get "$f" file)"; then OUT_NEEDED[$o]=1; OUT_REASON[$o]="its file is gone"
    else OUT_NEEDED[$o]=0; OUT_REASON[$o]="unchanged"
    fi
  done
}

short_id() { # a commit (or commit+local-hash) id, shortened for messages
  local id="$1"
  if [[ "$id" == *"+"* ]]; then printf '%s+%s' "${id:0:12}" "${id#*+}"; else printf '%s' "${id:0:12}"; fi
}

diff_words() { # the words that differ between two settings texts: "<old ones> -> <new ones>"
  local a="$1" b="$2" w old="" new=""
  for w in $a; do [[ " $b " == *" $w "* ]] || old+="${w} "; done
  for w in $b; do [[ " $a " == *" $w "* ]] || new+="${w} "; done
  printf '%s -> %s' "${old:-(none) }" "${new:-(none) }" | sed 's/ -> /|/; s/ *|/ -> /; s/ *$//'
}
diff_deps() { # "name old -> new" for the packages that changed
  local oldf="$1" new="$2" name ver out="" n=0
  declare -A OLD=() NEW=()
  [[ -f "$oldf" ]] && while IFS='=' read -r name ver; do [[ -n "$name" ]] && OLD[$name]="$ver"; done < "$oldf"
  while IFS='=' read -r name ver; do [[ -n "$name" ]] && NEW[$name]="$ver"; done <<< "$new"
  for name in "${!NEW[@]}"; do
    if [[ "${OLD[$name]:-}" != "${NEW[$name]}" ]]; then out+="${name} ${OLD[$name]:-new} -> ${NEW[$name]}, "; n=$((n + 1)); fi
  done
  for name in "${!OLD[@]}"; do [[ -v "NEW[$name]" ]] || { out+="${name} removed, "; n=$((n + 1)); }; done
  if (( n > 6 )); then printf '%d packages' "$n"; else printf '%s' "${out%, }"; fi
}

# How each output is made: raise the number when the steps change, so existing outputs are made again.
declare -A RECIPE=([install]=1 [appimage]=2 [deb]=1 [rpm]=2)
output_extra() { # what besides the build goes into an output
  case "$1" in
    install) printf 'recipe=%s prefix=%s' "${RECIPE[install]}" "${S[PREFIX_PATH]}" ;;
    appimage) printf 'recipe=%s tools=%s plugins=%s' "${RECIPE[appimage]}" "$(tools_hash)" "$(printf '%s' "$GST_PLUGINS" | sha256_of | cut -c1-12)" ;;
    deb|rpm) printf 'recipe=%s tests=%s' "${RECIPE[$1]}" "${S[TESTS]}" ;;
  esac
}
tools_hash() {
  local f out=""
  for f in "${S[TOOLS_PATH]}/linuxdeploy-${TOOL_ARCH}.AppImage" "${S[TOOLS_PATH]}/linuxdeploy-plugin-qt-${TOOL_ARCH}.AppImage" \
           "${S[TOOLS_PATH]}/linuxdeploy-plugin-gstreamer.sh"; do
    [[ -f "$f" ]] && out+="$(stat -c '%s-%Y' "$f")"
  done
  printf '%s' "$out" | sha256_of | cut -c1-12
}
output_present() {
  local o="$1" file="$2"
  case "$o" in
    install) [[ -x "${S[PREFIX_PATH]}/bin/akousma" ]] ;;
    *) [[ -n "$file" && -f "$file" ]] ;;
  esac
}
write_stamp() { # $1 = name, rest: key=value lines
  local name="$1"; shift
  mkdir -p "$STAMP_DIR"
  printf '%s\n' "$@" > "${STAMP_DIR}/${name}.stamp"
}

print_plan() {
  step "What this run does"
  if [[ "$KDSA_FROM_SOURCE" == 1 ]]; then
    if [[ -f "${STAMP_DIR}/kdsingleapplication.stamp" && -d "$DEPS_PREFIX" ]]; then info "kdsingleapplication: built (${KDSA_REF}; rebuilt only if its commit or Qt changes)"
    else info "kdsingleapplication: build ${KDSA_REF} from source (the distribution's is missing or too old)"; fi
  fi
  if (( BUILD_NEEDED )); then info "akousma:  build ($(printf '%s; ' "${BUILD_REASONS[@]}" | sed 's/; $//'))"
  else info "akousma:  skip (unchanged: akousma $(short_id "$AKOUSMA_ID"), settings, packages)"; fi
  local o
  for o in "${OUTPUTS[@]}"; do
    if (( BUILD_NEEDED )) || [[ "${OUT_NEEDED[$o]}" == 1 ]]; then
      local why="${OUT_REASON[$o]}"; (( BUILD_NEEDED )) && [[ "$why" == unchanged ]] && why="the build changed"
      printf '    %-9s %s\n' "${o}:" "make (${why})"
    else
      printf '    %-9s %s\n' "${o}:" "skip (unchanged)"
    fi
  done
}

# ---------------------------------------------------------------------------------------------------------------------
# Build steps
# ---------------------------------------------------------------------------------------------------------------------
check_tools() {
  local t missing=()
  for t in git cmake pkg-config; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
  command -v c++ >/dev/null 2>&1 || command -v g++ >/dev/null 2>&1 || command -v clang++ >/dev/null 2>&1 || missing+=("a C++ compiler")
  (( ${#missing[@]} == 0 )) || die "Missing: ${missing[*]} (--install-deps installs them)"
  local v; v="$(cmake --version | sed -n 's/^cmake version \([0-9.]*\).*/\1/p')"
  version_ge "$v" 3.25 || die "CMake ${v} is too old: Akousma needs 3.25 or newer (CMakeLists.txt cmake_minimum_required)"
}

akousma_version() { # the package version Akousma's CMake printed ("Package version:  1.0.0"), else from the source
  local v=""
  [[ -f "${LOG_DIR}/configure.log" ]] && v="$(sed -n 's/^-- Package version: *//p' "${LOG_DIR}/configure.log" | tail -n1)"
  if [[ -z "$v" && -f "${AKOUSMA_SRC}/cmake/AkousmaVersion.cmake" ]]; then
    v="$(awk -F'[ )]' '/^set\(AKOUSMA_VERSION_(MAJOR|MINOR|PATCH) /{printf "%s%s", sep, $2; sep="."}' "${AKOUSMA_SRC}/cmake/AkousmaVersion.cmake")"
  fi
  printf '%s' "${v:-0}"
}

build_akousma() {
  if (( ! BUILD_NEEDED )); then
    step "Akousma: unchanged ($(short_id "$AKOUSMA_ID")), not rebuilt"
    return 0
  fi
  step "Building Akousma ($(printf '%s; ' "${BUILD_REASONS[@]}" | sed 's/; $//'))"
  info "source: ${AKOUSMA_DESC}"
  local n; for n in "${AUTO_NOTES[@]}"; do info "note: ${n}"; done
  if [[ "$OPT_CLEAN" == 1 ]]; then info "Deleting ${CMAKE_BUILD_DIR}"; rm -rf "$CMAKE_BUILD_DIR"; fi
  rm -f "${STAMP_DIR}/build.stamp"
  # A build folder made with another generator or for another source folder can't be reused.
  local cache="${CMAKE_BUILD_DIR}/CMakeCache.txt"
  if [[ -f "$cache" ]] && ! grep -qx "CMAKE_GENERATOR:INTERNAL=${GENERATOR}" "$cache"; then
    info "The build folder was made with another CMake generator: starting it again"; rm -rf "$CMAKE_BUILD_DIR"
  elif [[ -f "$cache" ]] && ! grep -qxF "CMAKE_HOME_DIRECTORY:INTERNAL=${AKOUSMA_SRC}" "$cache"; then
    info "The build folder was made for another source folder ($(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$cache")): starting it again"
    rm -rf "$CMAKE_BUILD_DIR"
  fi
  mkdir -p "$CMAKE_BUILD_DIR"
  run_logged configure cmake -S "$AKOUSMA_SRC" -B "$CMAKE_BUILD_DIR" "${GENERATOR_ARGS[@]}" "${CONFIGURE_ARGS[@]}"
  progress build cmake --build "$CMAKE_BUILD_DIR" -j "${S[JOBS]}"
  if [[ "${S[TESTS]}" == ON ]]; then
    if grep -q '^build_tests' <(cmake --build "$CMAKE_BUILD_DIR" --target help 2>/dev/null | sed 's/^[. ]*//; s/:.*//'); then
      progress build-tests cmake --build "$CMAKE_BUILD_DIR" --target build_tests -j "${S[JOBS]}"
      local th="${S[BUILD_PATH]}/test-home"; rm -rf "$th"; mkdir -p "$th"; chmod 0700 "$th"
      run_logged tests env HOME="$th" XDG_RUNTIME_DIR="$th" QT_QPA_PLATFORM=offscreen \
        ctest --test-dir "$CMAKE_BUILD_DIR" --output-on-failure -j "${S[JOBS]}"
      ok "Tests passed"
    else
      warn "Akousma's tests are not configured (GTest / GMock / Qt Test not found)"
    fi
  fi
  write_stamp build "akousma=${AKOUSMA_ID}" "config=${CONFIG_HASH}" "deps=${DEPS_HASH}" "config_text=${CONFIG_TEXT}" \
    "source=${AKOUSMA_DESC}" "built=$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s\n' "$DEPS_TEXT" > "${STAMP_DIR}/build.deps"
  ok "Built ${CMAKE_BUILD_DIR}/akousma"
}

output_wanted() { (( BUILD_NEEDED )) || [[ "${OUT_NEEDED[$1]}" == 1 ]]; }

make_install() {
  local p="${S[PREFIX_PATH]}" marker="${S[PREFIX_PATH]}/.akousma-build-tools"
  output_wanted install || { step "Install folder: unchanged (${p})"; return 0; }
  step "Install folder ${p}"
  # A fresh copy each time, so files Akousma no longer installs don't stay behind; only in a folder this script made.
  if [[ -d "$p" ]]; then
    if [[ -f "$marker" ]]; then rm -rf "$p"
    elif [[ -n "$(ls -A "$p" 2>/dev/null)" ]]; then warn "${p} is not empty and was not made by ${SCRIPT_NAME}: installing over it"
    fi
  fi
  local sudo=()
  mkdir -p "$p" 2>/dev/null || true
  if [[ ! -w "$p" ]]; then sudo=(as_root); info "${p} is not writable: installing with $(root_prefix)"; fi
  run_logged install "${sudo[@]}" cmake --install "$CMAKE_BUILD_DIR"
  [[ -w "$p" ]] && printf 'Made by %s; deleted and installed again by each build.\n' "$SCRIPT_NAME" > "$marker"
  write_stamp install "build=${BUILD_ID}" "extra=$(output_extra install)" "file=${p}/bin/akousma"
  ok "Installed: ${p}/bin/akousma"
}

# -- AppImage ----------------------------------------------------------------------------------------------------------
download() { # url file
  local url="$1" file="$2" tmp
  mkdir -p "$(dirname "$file")"
  tmp="${file}.part"
  info "Downloading ${url}"
  if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 -o "$tmp" "$url" || { rm -f "$tmp"; die "Download failed: ${url}"; }
  elif command -v wget >/dev/null 2>&1; then wget -q -O "$tmp" "$url" || { rm -f "$tmp"; die "Download failed: ${url}"; }
  else die "curl or wget is needed to download ${url}"; fi
  mv -f "$tmp" "$file"
}

ensure_appimage_tools() {
  local t="${S[TOOLS_PATH]}" a="${TOOL_ARCH}" f url
  mkdir -p "$t"
  for f in "linuxdeploy-${a}.AppImage|${LINUXDEPLOY_URL//@ARCH@/$a}" "linuxdeploy-plugin-qt-${a}.AppImage|${LINUXDEPLOY_QT_URL//@ARCH@/$a}" \
           "linuxdeploy-plugin-gstreamer.sh|${LINUXDEPLOY_GST_URL}"; do
    url="${f#*|}"; f="${t}/${f%%|*}"
    if [[ ! -s "$f" || "$OPT_UPDATE_TOOLS" == 1 ]]; then download "$url" "$f"; fi
    chmod +x "$f"
  done
}

find_qmake() {
  local c
  for c in qmake6 qmake-qt6 /usr/lib/qt6/bin/qmake /usr/lib64/qt6/bin/qmake /usr/lib/*-linux-gnu/qt6/bin/qmake qmake; do
    if command -v "$c" >/dev/null 2>&1 && [[ "$("$c" -query QT_VERSION 2>/dev/null)" == 6.* ]]; then command -v "$c"; return 0; fi
  done
  return 1
}

make_appimage() {
  output_wanted appimage || { step "AppImage: unchanged ($(stamp_get "${STAMP_DIR}/appimage.stamp" file))"; return 0; }
  step "AppImage"
  local a="${S[ARCH]}" t="${S[TOOLS_PATH]}" work="${S[BUILD_PATH]}/appimage" appdir ver qmake out desktop icon
  ensure_appimage_tools
  qmake="$(find_qmake)" || die "qmake for Qt 6 not found (linuxdeploy-plugin-qt needs it)"
  for t in patchelf file; do command -v "$t" >/dev/null 2>&1 || die "${t} is needed for the AppImage (--install-deps installs it)"; done
  t="${S[TOOLS_PATH]}"
  appdir="${work}/AppDir"
  rm -rf "$work"; mkdir -p "$work"
  run_logged appimage-install cmake --install "$CMAKE_BUILD_DIR" --prefix "${appdir}/usr"

  # GStreamer: only the plugins on the list (upstream's), plus the plugin scanner.
  local pdir sdir staged="${work}/gst-plugins" helpers="${work}/gst-helpers" p missing=() n=0
  pdir="$(pkg-config --variable=pluginsdir gstreamer-1.0)"
  sdir="$(pkg-config --variable=pluginscannerdir gstreamer-1.0 2>/dev/null || true)"
  mkdir -p "$staged" "$helpers"
  # shellcheck disable=SC2086 # a list of names
  for p in $GST_PLUGINS; do
    if [[ -f "${pdir}/libgst${p}.so" ]]; then ln -s "${pdir}/libgst${p}.so" "$staged/"; n=$((n + 1)); else missing+=("$p"); fi
  done
  info "GStreamer: ${n} plugins from ${pdir}"
  (( ${#missing[@]} )) && info "not installed, left out: ${missing[*]}"
  # Both helpers: the plugin's AppRun hook ends with a test for gst-ptp-helper, and AppRun runs it with set -e, so an
  # AppImage without gst-ptp-helper would exit at once.
  for p in gst-plugin-scanner gst-ptp-helper; do
    [[ -n "$sdir" && -x "${sdir}/${p}" ]] && ln -s "${sdir}/${p}" "$helpers/"
  done
  [[ -e "${helpers}/gst-ptp-helper" ]] || warn "gst-ptp-helper not found in ${sdir:-?}: the AppImage may not start (linuxdeploy-plugin-gstreamer's AppRun hook)"

  desktop="$(find "${appdir}/usr/share/applications" -name '*.desktop' | head -n1)"
  icon="$(find "${appdir}/usr/share/icons/hicolor" -path '*/128x128/apps/akousma.png' | head -n1)"
  [[ -n "$desktop" && -n "$icon" ]] || die "The install has no .desktop file or 128x128 icon (${appdir}/usr/share)"
  ver="$(akousma_version)"

  local extra_platform=() qtplugins
  qtplugins="$("$qmake" -query QT_INSTALL_PLUGINS)"
  [[ -f "${qtplugins}/platforms/libqwayland-generic.so" ]] && extra_platform=("libqwayland-generic.so")
  [[ -f "${qtplugins}/platforms/libqwayland.so" ]] && extra_platform=("libqwayland.so")   # Qt 6.10+
  local extra_modules=""
  compgen -G "$(dirname "$("$qmake" -query QT_INSTALL_LIBS)/x")/libQt6Svg.so*" >/dev/null && extra_modules="svg"

  mkdir -p "${work}/out"
  # APPIMAGE_EXTRACT_AND_RUN: the tools run without FUSE (containers, systems without libfuse2).
  run_logged appimage-linuxdeploy env -C "${work}/out" \
    PATH="${t}:${PATH}" APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$a" QMAKE="$qmake" \
    EXTRA_PLATFORM_PLUGINS="$(IFS=';'; printf '%s' "${extra_platform[*]}")" EXTRA_QT_MODULES="$extra_modules" \
    GSTREAMER_PLUGINS_DIR="$staged" GSTREAMER_HELPERS_DIR="$helpers" \
    LINUXDEPLOY_OUTPUT_VERSION="$ver" \
    "${t}/linuxdeploy-${TOOL_ARCH}.AppImage" --appdir "$appdir" --desktop-file "$desktop" --icon-file "$icon" \
      --plugin qt --plugin gstreamer --output appimage
  out="$(find "${work}/out" -maxdepth 1 -name '*.AppImage' | head -n1)"
  [[ -n "$out" ]] || die "linuxdeploy made no AppImage (see ${LOG_DIR}/appimage-linuxdeploy.log)"
  mkdir -p "${S[OUTPUT_PATH]}"
  local dest="${S[OUTPUT_PATH]}/Akousma-${ver}-${a}.AppImage"
  mv -f "$out" "$dest"
  write_stamp appimage "build=${BUILD_ID}" "extra=$(output_extra appimage)" "file=${dest}"
  ok "AppImage: ${dest}"
}

# -- .deb (Akousma's debian/ with dpkg-buildpackage) -------------------------------------------------------------------
# dpkg-buildpackage builds in the source tree, so it works on a copy in <build path>/deb/akousma (never in your
# checkout). The copy keeps its obj-* build folder between runs, so a rebuild is incremental too.
copy_source_tree() { # src dest
  local src="$1" dest="$2"
  mkdir -p "$dest"
  find "$dest" -mindepth 1 -maxdepth 1 ! -name 'obj-*' -exec rm -rf {} +
  if [[ "$AKOUSMA_IS_GIT" == 1 ]]; then
    (cd "$src" && git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do
       [[ -e "$f" || -L "$f" ]] && printf '%s\0' "$f"; done | tar --null -T - -cf -) | tar -xf - -C "$dest"
  else
    (cd "$src" && tar --exclude=./.git --exclude=./build --exclude='./obj-*' -cf - .) | tar -xf - -C "$dest"
  fi
}

make_deb() {
  output_wanted deb || { step ".deb: unchanged ($(stamp_get "${STAMP_DIR}/deb.stamp" file))"; return 0; }
  step ".deb with Akousma's debian/ (dpkg-buildpackage)"
  command -v dpkg-buildpackage >/dev/null 2>&1 || die "dpkg-buildpackage is missing (--install-deps installs dpkg-dev)"
  [[ -f "${AKOUSMA_SRC}/debian/control" && -f "${AKOUSMA_SRC}/debian/changelog.in" ]] || die "${AKOUSMA_SRC} has no debian/ folder"
  local work="${S[BUILD_PATH]}/deb" tree ver codename
  tree="${work}/akousma"
  rm -f "${work}"/*.deb "${work}"/*.ddeb "${work}"/*.buildinfo "${work}"/*.changes
  copy_source_tree "$AKOUSMA_SRC" "$tree"
  # debian/changelog: what Akousma's debian/CMakeLists.txt makes from changelog.in at configure time.
  ver="$(akousma_version)"
  codename="${DISTRO_CODENAME:-$(lsb_release -cs 2>/dev/null || echo unstable)}"
  sed -e "s/\${AKOUSMA_VERSION_PACKAGE}/${ver}/g" -e "s/\${DEB_CODENAME}/${codename}/g" \
      -e "s/\${DEB_DATE}/$(LC_ALL=C date '+%a, %-d %b %Y %H:%M:%S %z')/g" \
      "${tree}/debian/changelog.in" > "${tree}/debian/changelog"
  local opts="parallel=${S[JOBS]}"; [[ "${S[TESTS]}" == ON ]] || opts="nocheck ${opts}"
  local envs=(DEB_BUILD_OPTIONS="$opts")
  [[ "$KDSA_FROM_SOURCE" == 1 ]] && envs+=(CMAKE_PREFIX_PATH="$DEPS_PREFIX")
  # -d: the dependencies were checked above (Build-Depends names a KDSingleApplication that may come from source here).
  progress deb-build env -C "$tree" "${envs[@]}" dpkg-buildpackage -b -uc -us -nc -d -j"${S[JOBS]}"
  mkdir -p "${S[OUTPUT_PATH]}"
  local f made=()
  # The package itself first (its stamp and the summary name it), then -dbgsym (.ddeb on Ubuntu, .deb on Debian).
  for f in "${work}"/*.deb "${work}"/*.ddeb; do
    [[ -f "$f" ]] || continue
    cp -f "$f" "${S[OUTPUT_PATH]}/"
    if [[ "${f##*/}" == *-dbgsym_* ]]; then made+=("${S[OUTPUT_PATH]}/${f##*/}"); else made=("${S[OUTPUT_PATH]}/${f##*/}" "${made[@]}"); fi
  done
  (( ${#made[@]} )) || die "dpkg-buildpackage made no .deb (see ${LOG_DIR}/deb-build.log)"
  write_stamp deb "build=${BUILD_ID}" "extra=$(output_extra deb)" "file=${made[0]}"
  for f in "${made[@]}"; do ok ".deb: ${f}"; done
}

# -- .rpm (Akousma's dist/unix/akousma.spec.in, as its "rpm" CMake target does it) ---------------------------------------
make_rpm() {
  output_wanted rpm || { step ".rpm: unchanged ($(stamp_get "${STAMP_DIR}/rpm.stamp" file))"; return 0; }
  step ".rpm with Akousma's spec (rpmbuild)"
  command -v rpmbuild >/dev/null 2>&1 || die "rpmbuild is missing (--install-deps installs rpm-build)"
  local spec="${CMAKE_BUILD_DIR}/akousma.spec" top="${S[BUILD_PATH]}/rpmbuild" ver
  # Akousma's CMake writes akousma.spec only when lsb_release and rpmbuild were there at configure time.
  if [[ ! -f "$spec" ]]; then
    run_logged configure cmake -S "$AKOUSMA_SRC" -B "$CMAKE_BUILD_DIR" "${GENERATOR_ARGS[@]}" "${CONFIGURE_ARGS[@]}"
  fi
  [[ -f "$spec" ]] || die "Akousma's CMake made no akousma.spec (needs lsb_release and rpmbuild; see ${LOG_DIR}/configure.log)"
  [[ -x "${AKOUSMA_SRC}/dist/scripts/maketarball.sh" ]] || die "${AKOUSMA_SRC}/dist/scripts/maketarball.sh is missing (made by Akousma's CMake)"
  rm -rf "$top"; mkdir -p "${top}"/{SOURCES,SPECS,BUILD,RPMS,SRPMS}
  ver="$(akousma_version)"
  run_logged rpm-tarball env -C "${top}/SOURCES" "${AKOUSMA_SRC}/dist/scripts/maketarball.sh"
  cp -f "$spec" "${top}/SPECS/akousma.spec"
  # Akousma installs io.github.genki_jp0.Akousma.metainfo.xml, but the spec's %files still names *.appdata.xml.
  if grep -q 'appdata\.xml' "${top}/SPECS/akousma.spec" && compgen -G "${AKOUSMA_SRC}/dist/unix/*.metainfo.xml" >/dev/null; then
    warn "Akousma's akousma.spec lists *.appdata.xml, but Akousma installs *.metainfo.xml: fixed in the build's copy of the spec (fix it in Akousma: dist/unix/akousma.spec.in)."
    sed -i 's/\*\.appdata\.xml/*.metainfo.xml/g' "${top}/SPECS/akousma.spec"
  fi
  # ... and its %files has no line for share/akousma (the icon sets, iconsets/*.rcc), which Akousma installs.
  if [[ -d "${AKOUSMA_SRC}/data/iconsets" ]] && ! grep -q '_datadir}/%{name}\|_datadir}/akousma' "${top}/SPECS/akousma.spec"; then
    warn "Akousma's akousma.spec doesn't package share/akousma (iconsets/*.rcc): added %{_datadir}/akousma/ to %files in the build's copy (fix it in Akousma: dist/unix/akousma.spec.in)."
    sed -i 's|^%{_bindir}/akousma$|&\n%{_datadir}/akousma/|' "${top}/SPECS/akousma.spec"
  fi
  local check=(--nocheck); [[ "${S[TESTS]}" == ON ]] && check=()
  progress rpm-build rpmbuild -bb "${check[@]}" --define "_topdir ${top}" --define "_smp_mflags -j${S[JOBS]}" "${top}/SPECS/akousma.spec"
  mkdir -p "${S[OUTPUT_PATH]}"
  local f made=()
  # The package itself first, then -debuginfo / -debugsource.
  while IFS= read -r -d '' f; do cp -f "$f" "${S[OUTPUT_PATH]}/"; made+=("${S[OUTPUT_PATH]}/${f##*/}"); done \
    < <(find "${top}/RPMS" -name '*.rpm' ! -name '*-debug*' -print0; find "${top}/RPMS" -name '*-debug*.rpm' -print0)
  (( ${#made[@]} )) || die "rpmbuild made no .rpm (see ${LOG_DIR}/rpm-build.log)"
  write_stamp rpm "build=${BUILD_ID}" "extra=$(output_extra rpm)" "file=${made[0]}"
  for f in "${made[@]}"; do ok ".rpm: ${f}"; done
}

# ---------------------------------------------------------------------------------------------------------------------
# Summary for --dry-run
# ---------------------------------------------------------------------------------------------------------------------
print_settings() { # the settings as given (the locations as resolved for the first architecture)
  step "Settings (${SETTINGS_FILE}: ${SETTINGS_NOTE})"
  local k src
  for k in "${SETTING_KEYS[@]}"; do
    if [[ -v "CLI[$k]" ]]; then src="command line"
    elif [[ -v "FILESET[$k]" && "${FILESET[$k]}" == "${DEFAULTS[$k]}" ]]; then src="file, default"
    elif [[ -v "FILESET[$k]" ]]; then src="file"
    else src="default"; fi
    printf '    %-16s %-58s (%s)\n' "$k" "${S[$k]:-<empty>}" "$src"
  done
  info "(locations as resolved for ${ARCH_NAME}; each architecture's are shown in its section)"
}

print_resolved() {
  step "Folders (${ARCH_NAME})"
  info "Akousma source:   ${AKOUSMA_SRC}"
  info "CMake build:      ${CMAKE_BUILD_DIR}"
  info "Step logs:        ${LOG_DIR}"
  info "Stamps:           ${STAMP_DIR}"
  [[ "$KDSA_FROM_SOURCE" == 1 ]] && info "KDSingleApplication: ${S[SRC_PATH]}/kdsingleapplication -> ${DEPS_PREFIX}"
  info "Install folder:   ${S[PREFIX_PATH]}"
  has_output appimage && info "AppImage:         ${S[OUTPUT_PATH]}/Akousma-<version>-${S[ARCH]}.AppImage (AppDir: ${S[BUILD_PATH]}/appimage)"
  if has_output appimage; then
    local f t=()
    for f in "linuxdeploy-${TOOL_ARCH}.AppImage" "linuxdeploy-plugin-qt-${TOOL_ARCH}.AppImage" linuxdeploy-plugin-gstreamer.sh; do
      if [[ -f "${S[TOOLS_PATH]}/$f" ]]; then t+=("${f} (there)"); else t+=("${f} (to download)"); fi
    done
    info "AppImage tools:   ${S[TOOLS_PATH]}: $(IFS=','; printf '%s' "${t[*]}" | sed 's/,/, /g')"
  fi
  has_output deb && info ".deb:             ${S[OUTPUT_PATH]} (dpkg-buildpackage in ${S[BUILD_PATH]}/deb/akousma)"
  has_output rpm && info ".rpm:             ${S[OUTPUT_PATH]} (rpmbuild in ${S[BUILD_PATH]}/rpmbuild)"
  info "Run log:          ${S[LOG_PATH]}"
  step "Akousma"
  info "${AKOUSMA_DESC}"
  info "outputs: ${OUTPUTS[*]:-none}; build type ${S[BUILD_TYPE]} (${CMAKE_BUILD_TYPE}); jobs ${S[JOBS]}; tests ${S[TESTS]}"
  info "cmake $(quote_cmd -S "$AKOUSMA_SRC" -B "$CMAKE_BUILD_DIR" "${GENERATOR_ARGS[@]}" "${CONFIGURE_ARGS[@]}")"
  [[ -n "$LOCK_FILE" ]] && info "release lock: ${LOCK_FILE}"
  [[ -n "$OPT_FREEZE" ]] && info "--freeze-deps ${OPT_FREEZE}: this architecture's section of ${VERSIONS_DIR}/${OPT_FREEZE}.txt"
  return 0
}

# ---------------------------------------------------------------------------------------------------------------------
# Architectures and containers
# ---------------------------------------------------------------------------------------------------------------------
canonical_arch() { # amd64 / i386 / arm64 for any of their names; fails for others
  case "${1,,}" in
    amd64|x86_64|x64) echo amd64 ;;
    i386|i486|i586|i686|x86) echo i386 ;;
    arm64|aarch64) echo arm64 ;;
    *) return 1 ;;
  esac
}

parse_arch_list() { # $1 = the ARCHS setting -> ARCH_LIST (order kept, duplicates dropped)
  local a c
  ARCH_LIST=()
  for a in ${1//,/ }; do
    c="$(canonical_arch "$a")" || die "Unknown architecture '${a}' in '${1}' (amd64, i386, arm64; also x86_64, i686, aarch64)"
    [[ " ${ARCH_LIST[*]} " == *" $c "* ]] || ARCH_LIST+=("$c")
  done
  (( ${#ARCH_LIST[@]} )) || die "No architecture (ARCHS / --arch: amd64, i386, arm64)"
}

is_native() { [[ "$1" == "$HOST_ARCH" ]]; }
# i386 programs run on an amd64 kernel as they are; every other foreign architecture needs qemu-user.
needs_qemu() { ! is_native "$1" && ! [[ "$1" == i386 && "$HOST_ARCH" == amd64 ]]; }

# The base image of an architecture: CONTAINER_IMAGES, else this distribution's release when it has an image (and the
# packages) for that architecture, so the packages match this machine's build; else Debian 13.
arch_base_image() {
  local a="$1" entry
  for entry in ${S[CONTAINER_IMAGES]//,/ }; do
    if [[ "$(canonical_arch "${entry%%=*}" || true)" == "$a" && -n "${entry#*=}" ]]; then printf '%s' "${entry#*=}"; return 0; fi
  done
  case "$DISTRO_ID" in
    debian) printf 'docker.io/library/debian:%s' "${DISTRO_CODENAME:-trixie}" ;;
    ubuntu) if [[ "$a" != i386 && -n "$DISTRO_VERSION" ]]; then printf 'docker.io/library/ubuntu:%s' "$DISTRO_VERSION"; else printf '%s' "$DEBIAN_IMAGE"; fi ;;
    fedora) if [[ "$a" != i386 && -n "$DISTRO_VERSION" ]]; then printf 'registry.fedoraproject.org/fedora:%s' "$DISTRO_VERSION"; else printf '%s' "$DEBIAN_IMAGE"; fi ;;
    opensuse-tumbleweed) if [[ "$a" != i386 ]]; then printf 'registry.opensuse.org/opensuse/tumbleweed:latest'; else printf '%s' "$DEBIAN_IMAGE"; fi ;;
    *) printf '%s' "$DEBIAN_IMAGE" ;;
  esac
}
image_ref() { # $1 = arch, $2 = base image: the build image made from it
  local slug="${2,,}"
  slug="$(printf '%s' "$slug" | tr -c 'a-z0-9._-' '-' | sed 's/^[.-]*//')"
  printf '%s:%s-%s' "$IMAGE_REPO" "$1" "${slug:0:100}"
}
image_recipe() { # what a build image is made of: the recipe number, the base image and the package lists
  local k
  { printf 'recipe=%s base=%s\n' "$IMAGE_RECIPE" "$1"
    while IFS= read -r k; do printf '%s=%s\n' "$k" "${PKGS[$k]}"; done < <(printf '%s\n' "${!PKGS[@]}" | sort)
  } | sha256_of | cut -c1-16
}
image_label() { "$ENGINE" image inspect --format "{{index .Config.Labels \"${2}\"}}" "$1" 2>/dev/null | grep -v '^<no value>$' || true; }
image_digest() { "$ENGINE" image inspect --format '{{range .RepoDigests}}{{.}} {{end}}' "$1" 2>/dev/null | awk '{print $1}' || true; }
# The command that runs in the container: the personality of a 32-bit machine for i386 (uname -m says i686, as CMake
# and the AppImage tools expect), under a shell that ends the container on Ctrl-C (a process 1 ignores SIGINT).
container_command() { # $1 = arch, rest = command -> CCMD
  local a="$1"; shift
  local pers=(); [[ "$a" == i386 ]] && pers=(setarch i686)
  # shellcheck disable=SC2016 # expanded by the container's shell
  CCMD=(sh -c 'trap "exit 130" INT TERM; "$@" & wait $!' sh "${pers[@]}" "$@")
}
container_env() { # -> CENV: the environment passed into a container
  local v
  CENV=(-e LANG=C.UTF-8 -e DEBIAN_FRONTEND=noninteractive -e "AKOUSMA_BUILD_COLOR=${AKOUSMA_BUILD_COLOR:-0}")
  for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do [[ -n "${!v:-}" ]] && CENV+=(-e "$v"); done
  read -r -a CEXTRA <<< "${S[CONTAINER_ARGS]}"
  return 0
}

# CONTAINER_ENGINE auto: podman (no daemon, rootless) if it works, else docker. Sets ENGINE, or ENGINE_PROBLEM.
select_engine() {
  local want="${S[CONTAINER_ENGINE],,}" e err cands=()
  ENGINE="" ENGINE_PROBLEM=""
  case "$want" in
    auto|"") cands=(podman docker) ;;
    podman|docker) cands=("$want") ;;
    *) die "CONTAINER_ENGINE must be podman, docker or auto (is '${S[CONTAINER_ENGINE]}')" ;;
  esac
  for e in "${cands[@]}"; do
    command -v "$e" >/dev/null 2>&1 || continue
    if err="$("$e" info 2>&1 >/dev/null)"; then ENGINE="$e"; return 0; fi
    ENGINE_PROBLEM+="${e} is installed, but '${e} info' fails ($(printf '%s\n' "$err" | grep -m1 . | cut -c1-160)). "
  done
  [[ -n "$ENGINE_PROBLEM" ]] || ENGINE_PROBLEM="no container engine: $(IFS=/; printf '%s' "${cands[*]}") is not installed."
  ENGINE_PROBLEM="${ENGINE_PROBLEM% }"
  return 0
}

# The binfmt_misc entry of the qemu-user handler for $1 (aarch64, x86_64, i386), by its name or its interpreter.
binfmt_entry() {
  local d=/proc/sys/fs/binfmt_misc f
  for f in "$d"/*; do
    [[ -f "$f" && "${f##*/}" != status && "${f##*/}" != register ]] || continue
    if [[ "${f##*/}" == "qemu-${1}" ]] || grep -Eq "^interpreter .*(qemu-${1}([^a-z0-9_]|$)|/${1}-binfmt)" "$f" 2>/dev/null; then
      printf '%s' "$f"; return 0
    fi
  done
  return 0
}
# Its state: ok, nofix (registered without the F flag: the interpreter is then looked up inside the container, where it
# isn't), disabled, missing, or unknown (binfmt_misc is not mounted).
binfmt_state() {
  local f
  [[ -e /proc/sys/fs/binfmt_misc/status ]] || { echo unknown; return 0; }
  f="$(binfmt_entry "$1")"
  if [[ -z "$f" ]]; then echo missing
  elif ! grep -qx enabled "$f"; then echo disabled
  elif grep -Eq '^flags:.*F' "$f"; then echo ok
  else echo nofix
  fi
}
qemu_packages() { # $1 = qemu name: the packages that bring that qemu-user with its binfmt_misc registration
  case "$PM" in
    apt) echo qemu-user-static ;;
    dnf) if [[ "$1" == aarch64 ]]; then echo qemu-user-static-aarch64; else echo qemu-user-static-x86; fi ;;
    pacman) echo qemu-user-static qemu-user-static-binfmt ;;
    zypper) echo qemu-linux-user ;;
  esac
}
# After installing qemu-user: systemd-binfmt registers the handlers of /usr/lib/binfmt.d; without systemd (containers,
# WSL) the script writes them to /proc/sys/fs/binfmt_misc/register itself.
register_binfmt() {
  local q conf c line f flags
  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    info "Running: $(root_prefix)systemctl restart systemd-binfmt"
    as_root systemctl restart systemd-binfmt || warn "systemctl restart systemd-binfmt failed"
  fi
  for q; do
    [[ "$(binfmt_state "$q")" == ok ]] && continue
    conf=""
    for c in /usr/lib/binfmt.d/qemu-"${q}".conf /usr/lib/binfmt.d/qemu-"${q}"-static.conf; do [[ -f "$c" ]] && { conf="$c"; break; }; done
    if [[ -z "$conf" ]]; then warn "No /usr/lib/binfmt.d/qemu-${q}.conf: register qemu-${q} in binfmt_misc yourself (see linux/BUILD.txt)"; continue; fi
    line="$(grep -v -m1 -E '^[[:space:]]*([#;]|$)' "$conf" || true)"
    [[ -n "$line" ]] || continue
    # Containers need the F flag (the kernel opens the interpreter when it is registered).
    flags="${line##*:}"; [[ "$flags" == *F* ]] || line="${line%:*}:${flags}F"
    [[ -e /proc/sys/fs/binfmt_misc/register ]] || as_root mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc || true
    f="$(binfmt_entry "$q")"
    if [[ -n "$f" ]]; then printf '%s' -1 | as_root tee "$f" >/dev/null || true; fi   # without F or disabled: replaced
    info "Registering qemu-${q} (${conf}, flags ${line##*:}) in /proc/sys/fs/binfmt_misc"
    printf '%s' "$line" | as_root tee /proc/sys/fs/binfmt_misc/register >/dev/null || warn "Registering ${conf} failed"
  done
}

# What the architectures built in a container need on this machine: a container engine, and qemu-user for those that
# don't run natively. Checked before anything is built; --install-deps installs what is missing (podman,
# qemu-user-static). Sets ARCH_BLOCKED[arch] for each architecture that can't be built, and FOREIGN_FIX.
declare -A ARCH_BLOCKED=()
setup_foreign() {
  local a q st foreign=() qemu_need=() pkgs=() p cmdline
  for a in "${ARCH_LIST[@]}"; do is_native "$a" || foreign+=("$a"); done
  (( ${#foreign[@]} )) || return 0
  select_engine
  # No engine that works: podman (rootless, no daemon), unless CONTAINER_ENGINE asks for docker.
  [[ -n "$ENGINE" || "${S[CONTAINER_ENGINE],,}" == docker ]] || pkgs+=(podman)
  for a in "${foreign[@]}"; do
    needs_qemu "$a" || continue
    q="${ARCH_QEMU[$a]}"; st="$(binfmt_state "$q")"
    if [[ "$st" == missing || "$st" == nofix || "$st" == disabled ]]; then
      qemu_need+=("$q")
      for p in $(qemu_packages "$q"); do [[ " ${pkgs[*]} " == *" $p "* || -n "$(pkg_installed_version "$p")" ]] || pkgs+=("$p"); done
    fi
  done
  FOREIGN_FIX=""
  if (( ${#pkgs[@]} )) && [[ -n "$PM" ]]; then
    install_cmd "${pkgs[@]}"; cmdline="$(root_prefix)$(quote_cmd "${INSTALL_CMD[@]}")"
    FOREIGN_FIX="./${SCRIPT_NAME} --install-deps (it runs: ${cmdline})"
  elif (( ${#pkgs[@]} )); then
    FOREIGN_FIX="install podman (or docker) and qemu-user-static, and register qemu in binfmt_misc (see linux/BUILD.txt)"
  elif (( ${#qemu_need[@]} )); then
    FOREIGN_FIX="./${SCRIPT_NAME} --install-deps (registers the installed qemu-user handlers in binfmt_misc)"
  fi
  if [[ "$OPT_INSTALL_DEPS" == 1 && "$OPT_DRY_RUN" == 0 && "$OPT_LIST" == 0 && "$OPT_CHECK_DEPS" == 0 ]] && \
     (( ${#pkgs[@]} + ${#qemu_need[@]} )); then
    step "Container engine and qemu-user for ${foreign[*]}"
    if (( ${#pkgs[@]} )); then
      [[ -n "$PM" ]] || die "Unknown distribution: install podman (or docker) and qemu-user-static yourself (see linux/BUILD.txt)"
      if [[ "$PM" == apt ]]; then info "Running: $(root_prefix)apt-get update"; as_root apt-get update || die "apt-get update failed"; fi
      info "Running: ${cmdline}"
      as_root "${INSTALL_CMD[@]}" || die "Installing ${pkgs[*]} failed. The command was: ${cmdline}"
    fi
    (( ${#qemu_need[@]} )) && register_binfmt "${qemu_need[@]}"
    select_engine
  fi
  for a in "${foreign[@]}"; do
    if [[ -z "$ENGINE" ]]; then ARCH_BLOCKED[$a]="${ENGINE_PROBLEM}"; continue; fi
    needs_qemu "$a" || continue
    q="${ARCH_QEMU[$a]}"
    case "$(binfmt_state "$q")" in
      missing) ARCH_BLOCKED[$a]="${a} programs can't run on this ${HOST_ARCH} machine: qemu-user for ${q} is not registered in binfmt_misc." ;;
      nofix) ARCH_BLOCKED[$a]="qemu-${q} is registered in binfmt_misc without the F (fix binary) flag, so it can't run inside a container." ;;
      disabled) ARCH_BLOCKED[$a]="qemu-${q} is disabled in binfmt_misc." ;;
    esac
  done
  return 0
}

print_arch_overview() {
  local a how st
  step "Architectures: ${ARCH_LIST[*]}"
  for a in "${ARCH_LIST[@]}"; do
    if is_native "$a"; then how="this machine (${DISTRO_NAME}), {ARCH} ${ARCH_DIR[$a]}"
    else
      how="container ${ENGINE:-(no engine)}, base image $(arch_base_image "$a"), {ARCH} ${ARCH_DIR[$a]}"
      if needs_qemu "$a"; then
        st="$(binfmt_state "${ARCH_QEMU[$a]}")"
        how+=", qemu-${ARCH_QEMU[$a]} (binfmt_misc: ${st})"
      else how+=", runs natively"; fi
    fi
    printf '    %-6s %s\n' "$a" "$how"
    [[ -n "${ARCH_BLOCKED[$a]:-}" ]] && printf '    %s       %s%s%s\n' "" "$C_WARN" "can't be built: ${ARCH_BLOCKED[$a]}" "$C_OFF"
  done
  return 0
}

# Makes the build image of a foreign architecture when it is missing or out of date: pulls the base image, checks
# that its programs run here, runs --image-setup in it (installs every package group) and commits the container.
# Runs in a subshell: a failure ends only this architecture.
prepare_image() {
  local a="$1" base ref recipe have tmp out want
  base="$(arch_base_image "$a")"; ref="$(image_ref "$a" "$base")"; recipe="$(image_recipe "$base")"
  have="$(image_label "$ref" akousma.recipe)"
  if [[ "$have" == "$recipe" && "$OPT_UPDATE_IMAGES" == 0 ]]; then info "Image ${ref} (from ${base})"; return 0; fi
  if [[ -z "$have" ]]; then info "Making the image ${ref} from ${base} (once; --update-images makes it again)"
  elif [[ "$have" != "$recipe" ]]; then info "The image ${ref} is out of date (base image or package lists changed): making it again"
  else info "--update-images: making ${ref} again from the newest ${base}"; fi
  run_logged image-pull "$ENGINE" pull --platform "${ARCH_PLATFORM[$a]}" "$base"
  if ! out="$("$ENGINE" run --rm --platform "${ARCH_PLATFORM[$a]}" "$base" uname -m 2>&1)"; then
    if [[ "$out" == *"exec format error"* ]] || needs_qemu "$a"; then
      die "${a} programs don't run here ($(printf '%s\n' "$out" | grep -m1 . | cut -c1-160)): qemu-user for ${ARCH_QEMU[$a]} must be registered in binfmt_misc with the F flag. ${FOREIGN_FIX:-./${SCRIPT_NAME} --install-deps sets it up.}"
    fi
    die "${ENGINE} can't run ${base} for ${ARCH_PLATFORM[$a]}: ${out}"
  fi
  out="$(printf '%s\n' "$out" | tail -n1)"
  case "$a" in amd64) want="x86_64" ;; i386) want="x86_64 i686 i386" ;; arm64) want="aarch64" ;; esac
  [[ " $want " == *" $out "* ]] || die "${base} for ${ARCH_PLATFORM[$a]} runs as ${out}, not ${a}: the engine didn't give that architecture's image"
  tmp="akousma-build-setup-${a}"
  "$ENGINE" rm -f "$tmp" >/dev/null 2>&1 || true
  # shellcheck disable=SC2064 # $tmp is fixed now
  trap "\"$ENGINE\" rm -f \"$tmp\" >/dev/null 2>&1 || true" EXIT
  container_env
  container_command "$a" bash "$SCRIPT_PATH" --image-setup --arch-build "$a" --host-arch "$HOST_ARCH"
  RUN_PROGRESS=0 run_logged image-setup "$ENGINE" run --name "$tmp" --platform "${ARCH_PLATFORM[$a]}" --network host \
    --security-opt label=disable -v "${SCRIPT_DIR}:${SCRIPT_DIR}:ro" "${CENV[@]}" "${CEXTRA[@]}" "$base" "${CCMD[@]}"
  run_logged image-commit "$ENGINE" commit --change "LABEL akousma.recipe=${recipe}" --change "LABEL akousma.base=${base}" "$tmp" "$ref"
  ok "Image ${ref}"
}

# The run of one architecture in its container: every folder it uses is mounted at the same path, so the settings,
# stamps and logs mean the same inside and out; the script folder read-only. The build runs as the calling user
# (podman: --userns=keep-id; docker: --user), so the files it makes are the user's.
run_in_container() {
  local a="$1" base ref p seen=" " mounts=() user=()
  shift
  base="$(arch_base_image "$a")"; ref="$(image_ref "$a" "$base")"
  local home="${S[BUILD_PATH]}/home" readonly_mode=0
  [[ "$OPT_DRY_RUN" == 1 || "$OPT_LIST" == 1 || "$OPT_CHECK_DEPS" == 1 ]] && { readonly_mode=1; [[ -d "$home" ]] || home=/tmp; }
  for p in "${S[BUILD_PATH]}" "${S[PREFIX_PATH]}" "${S[OUTPUT_PATH]}" "${S[TOOLS_PATH]}" "${S[SRC_PATH]}" \
           "${S[DOWNLOADS_PATH]}" "${S[AKOUSMA_SOURCE]}" "${S[BUILD_PATH]}/home"; do
    [[ -n "$p" ]] || continue
    [[ "$p" != *:* ]] || die "${p}: a folder with ':' in its name can't be mounted into the container"
    # --dry-run, --list, --check-deps change nothing: only the folders that are there already.
    if (( readonly_mode )); then [[ -d "$p" ]] || continue; else mkdir -p "$p" || die "Can't create ${p}"; fi
    [[ "$seen" == *" ${p} "* ]] && continue
    seen+="${p} "; mounts+=(-v "${p}:${p}")
  done
  for p in "$SCRIPT_DIR" "$(dirname "$SETTINGS_FILE")"; do
    [[ "$seen" == *" ${p} "* ]] && continue
    seen+="${p} "; mounts+=(-v "${p}:${p}:ro")
  done
  if [[ "$ENGINE" == podman && $EUID -ne 0 ]]; then user=(--userns=keep-id)
  elif [[ $EUID -ne 0 ]]; then user=(--user "$(id -u):$(id -g)"); fi
  container_env
  container_command "$a" bash "$SCRIPT_PATH" "$@"
  "$ENGINE" run --rm --platform "${ARCH_PLATFORM[$a]}" --network host --security-opt label=disable -w "$PWD" \
    "${user[@]}" "${mounts[@]}" -e "HOME=${home}" -e "AKOUSMA_BUILD_IMAGE=${base}" "${CENV[@]}" \
    "${CEXTRA[@]}" "$ref" "${CCMD[@]}"
}

# ---------------------------------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------------------------------
# The run the user starts: settings, then each architecture in turn (this machine's by this script in a new process,
# the others in their container), each in its own folders. One that fails doesn't stop the next; the run ends with a
# summary and exit code 1 if any architecture failed or couldn't be built.
main() {
  parse_args "$@"
  HOST_ARCH="${HOST_ARCH_OPT:-$(canonical_arch "$(uname -m)" || uname -m)}"
  load_settings
  if [[ "$OPT_IMAGE_SETUP" == 1 ]]; then image_setup_main; exit 0; fi
  if [[ -n "$ARCH_BUILD" ]]; then arch_main; exit 0; fi

  parse_arch_list "${S[ARCHS]}"
  resolve_settings "${ARCH_LIST[0]}"
  detect_distro
  local readonly_mode=0; [[ "$OPT_DRY_RUN" == 1 || "$OPT_LIST" == 1 || "$OPT_CHECK_DEPS" == 1 ]] && readonly_mode=1

  # The settings file: created on the first run, updated with --save-settings (also with --dry-run, so settings can be
  # saved without building).
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    write_settings; SETTINGS_NOTE="created with the defaults"
    [[ "$OPT_SAVE" == 1 ]] && SETTINGS_NOTE+=" and this command line's settings"
  elif [[ "$OPT_SAVE" == 1 ]]; then
    write_settings; SETTINGS_NOTE="saved this command line's settings"
  fi

  [[ -t 1 ]] && export AKOUSMA_BUILD_COLOR=1
  if (( ! readonly_mode )); then
    mkdir -p "$(dirname "${S[LOG_PATH]}")"
    # tee ignores Ctrl-C, so the run can still print its summary after an interrupted architecture.
    exec > >(trap '' INT; exec tee -a "${S[LOG_PATH]}") 2>&1
    printf '\n######## %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(quote_cmd "$0" "$@")"
  fi
  printf 'Build settings: %s (%s)\n' "$SETTINGS_FILE" "$SETTINGS_NOTE"
  [[ "$OPT_DRY_RUN" == 1 ]] && print_settings

  setup_foreign
  print_arch_overview

  # The Akousma commit, resolved (and fetched) once, so every architecture builds the same one.
  local pin=()
  AKOUSMA_COMMIT="" AKOUSMA_DESC=""
  local a buildable=0
  for a in "${ARCH_LIST[@]}"; do [[ -n "${ARCH_BLOCKED[$a]:-}" ]] || buildable=1; done
  if [[ "$OPT_CHECK_DEPS" == 0 && "$buildable" == 1 ]]; then
    find_lock
    resolve_akousma_source
    find_lock_by_commit
    [[ -n "$AKOUSMA_COMMIT" && "$AKOUSMA_ID" != *"+local-"* ]] && pin=(--pinned-commit "$AKOUSMA_COMMIT")
    if [[ -n "$OPT_FREEZE" ]]; then
      [[ -n "$AKOUSMA_COMMIT" ]] || die "--freeze-deps: the Akousma commit is not known"
      [[ "$AKOUSMA_ID" != *"+local-"* ]] || die "--freeze-deps: the checkout has uncommitted changes; a release lock needs a commit"
    fi
  fi

  local i=0 n=${#ARCH_LIST[@]} rc start total=$SECONDS image lockparts=() failed=() inst=()
  declare -A RESULT=() TOOK=()
  [[ "$OPT_INSTALL_DEPS" == 1 ]] && inst=(--install-deps)
  INTERRUPTED=0
  trap 'INTERRUPTED=1' INT
  for a in "${ARCH_LIST[@]}"; do
    i=$((i + 1))
    resolve_settings "$a"
    [[ -n "$OPT_FREEZE" ]] && rm -f "$(lock_part_file "$OPT_FREEZE")"
    (( readonly_mode )) || rm -f "${STAMP_DIR}/last-run"
    if is_native "$a"; then step "[${i}/${n}] ${a}: this machine"
    else step "[${i}/${n}] ${a}: container ($(arch_base_image "$a"))"; fi
    if [[ -n "${ARCH_BLOCKED[$a]:-}" ]]; then
      warn "${a} can't be built: ${ARCH_BLOCKED[$a]}"
      RESULT[$a]="not built: ${ARCH_BLOCKED[$a]}"; failed+=("$a"); continue
    fi
    start=$SECONDS rc=0
    if is_native "$a"; then
      bash "$SCRIPT_PATH" "${FWD_ARGS[@]}" "${inst[@]}" --settings "$SETTINGS_FILE" --arch-build "$a" \
        --host-arch "$HOST_ARCH" "${pin[@]}" || rc=$?
    else
      image="$(image_ref "$a" "$(arch_base_image "$a")")"
      if (( readonly_mode )) && [[ -z "$(image_label "$image" akousma.recipe)" ]]; then
        info "The image ${image} is not made yet: the first build makes it (pulls $(arch_base_image "$a"), installs the packages)."
        info "Its packages and plan show once it exists."
        RESULT[$a]="image not made yet"
        [[ "$OPT_CHECK_DEPS" == 1 || -n "$OPT_FREEZE" ]] && failed+=("$a")
        continue
      fi
      if (( ! readonly_mode )); then
        ( prepare_image "$a" ) || rc=$?
        if (( rc != 0 )); then
          (( INTERRUPTED )) && break
          RESULT[$a]="not built: its image could not be made (see above)"; failed+=("$a"); continue
        fi
      fi
      run_in_container "$a" "${FWD_ARGS[@]}" --settings "$SETTINGS_FILE" --arch-build "$a" --host-arch "$HOST_ARCH" \
        "${pin[@]}" || rc=$?
    fi
    (( INTERRUPTED )) && break
    TOOK[$a]="$(( (SECONDS - start) / 60 ))m $(( (SECONDS - start) % 60 ))s"
    if (( rc == 0 )); then
      RESULT[$a]="ok"
      if [[ "$OPT_CHECK_DEPS" == 1 ]]; then RESULT[$a]+=" (all packages there)"; elif (( readonly_mode )); then RESULT[$a]+=" (nothing built)"; fi
      local skipped; skipped="$(stamp_get "${STAMP_DIR}/last-run" skipped)"
      [[ -n "$skipped" ]] && RESULT[$a]+=" (not made here: ${skipped})"
      if [[ -n "$OPT_FREEZE" ]]; then
        image=""; is_native "$a" || image="$(arch_base_image "$a")"
        lockparts+=("${a}|$(lock_part_file "$OPT_FREEZE")|${image}")
      fi
    elif [[ "$OPT_CHECK_DEPS" == 1 && "$rc" == 1 ]]; then
      RESULT[$a]="packages missing (see above)"; failed+=("$a")
    else
      RESULT[$a]="FAILED (exit ${rc})"; failed+=("$a")
    fi
  done
  trap - INT
  if (( INTERRUPTED )); then printf '\n'; warn "Interrupted (${a})."; exit 130; fi

  if [[ -n "$OPT_FREEZE" ]]; then
    if (( ${#failed[@]} )); then
      warn "--freeze-deps ${OPT_FREEZE}: ${VERSIONS_DIR}/${OPT_FREEZE}.txt not written: ${failed[*]} not built (a release record covers every architecture of ARCHS; --arch selects them)"
    else
      write_lock_file "$OPT_FREEZE" "${lockparts[@]}"
    fi
  fi

  step "Architectures ($(( (SECONDS - total) / 60 ))m $(( (SECONDS - total) % 60 ))s)"
  for a in "${ARCH_LIST[@]}"; do
    local color="$C_OK"; [[ "${RESULT[$a]:-}" == ok* ]] || color="$C_ERR"
    [[ "${RESULT[$a]:-}" == "image not made yet" ]] && color="$C_WARN"
    printf '    %-6s %s%s%s%s\n' "$a" "$color" "${RESULT[$a]:-not run}" "$C_OFF" "${TOOK[$a]:+  (${TOOK[$a]})}"
  done
  if (( ${#failed[@]} )); then
    local why=""
    for a in "${failed[@]}"; do [[ -n "${ARCH_BLOCKED[$a]:-}" ]] && why=1; done
    [[ -n "$why" && -n "${FOREIGN_FIX:-}" ]] && info "To set up the container builds: ${FOREIGN_FIX}"
    if [[ -v "ARCH_DIR[$HOST_ARCH]" && " ${failed[*]} " != *" ${HOST_ARCH} "* ]]; then
      info "To build only this machine's architecture: --arch ${HOST_ARCH} (add --save-settings to keep it)."
    fi
    if (( readonly_mode )) && [[ "$OPT_CHECK_DEPS" == 0 && -z "$OPT_FREEZE" ]]; then return 0; fi
    [[ "$OPT_CHECK_DEPS" == 1 ]] && die "Not ready to build: ${failed[*]} (see above)."
    (( readonly_mode )) && die "Not complete for: ${failed[*]} (see above)."
    die "Not built: ${failed[*]} (see above)."
  fi
}

# The run of one architecture (--arch-build), on this machine or in its container.
arch_main() {
  resolve_settings "$ARCH_BUILD"
  detect_distro
  info "${ARCH_NAME} ({ARCH} ${S[ARCH]}) on ${DISTRO_NAME}${AKOUSMA_BUILD_IMAGE:+, container from ${AKOUSMA_BUILD_IMAGE}}"
  resolve_outputs
  local readonly_mode=0; [[ "$OPT_DRY_RUN" == 1 || "$OPT_LIST" == 1 || "$OPT_CHECK_DEPS" == 1 ]] && readonly_mode=1
  if (( ! readonly_mode )); then
    mkdir -p "$STAMP_DIR"
    printf 'skipped=%s\n' "$(IFS=,; printf '%s' "${SKIPPED_OUTPUTS[*]}")" > "${STAMP_DIR}/last-run"
  fi

  find_lock
  [[ -n "$LOCK_FILE" && -n "${LOCK[kdsingleapplication_ref]:-}" ]] && KDSA_REF="${LOCK[kdsingleapplication_ref]}"

  resolve_packages
  check_kdsa
  if [[ "$OPT_CHECK_DEPS" == 1 ]]; then
    ensure_packages
    (( ${#PKG_MISSING[@]} == 0 )) || exit 1
    exit 0
  fi
  ensure_packages
  check_kdsa

  resolve_akousma_source
  find_lock_by_commit
  [[ -n "$LOCK_FILE" && -n "${LOCK[kdsingleapplication_ref]:-}" ]] && KDSA_REF="${LOCK[kdsingleapplication_ref]}"
  compute_config
  detect_changes

  if [[ "$OPT_DRY_RUN" == 1 ]]; then
    print_resolved
    compare_lock
    print_plan
    if [[ -n "$OPT_FREEZE" ]]; then
      [[ -n "$AKOUSMA_COMMIT" ]] || die "--freeze-deps: the Akousma commit is not known"
      write_lock_part "$OPT_FREEZE"
    fi
    printf '\nDry run: nothing was built.\n'
    exit 0
  fi
  if [[ "$OPT_LIST" == 1 ]]; then
    info "Akousma: ${AKOUSMA_DESC}"
    compare_lock
    print_plan
    exit 0
  fi

  check_tools
  compare_lock
  [[ -n "$OPT_FREEZE" && "$AKOUSMA_ID" == *"+local-"* ]] && die "--freeze-deps: the checkout has uncommitted changes; a release lock needs a commit"
  print_plan
  local start=$SECONDS
  build_kdsa
  build_akousma
  has_output install && make_install
  has_output appimage && make_appimage
  has_output deb && make_deb
  has_output rpm && make_rpm
  [[ -n "$OPT_FREEZE" ]] && write_lock_part "$OPT_FREEZE"
  step "${ARCH_NAME}: done in $(( (SECONDS - start) / 60 ))m $(( (SECONDS - start) % 60 ))s"
  info "Akousma: ${AKOUSMA_DESC}"
  info "Build:   ${CMAKE_BUILD_DIR}/akousma"
  local o f
  for o in "${OUTPUTS[@]}"; do
    f="$(stamp_get "${STAMP_DIR}/${o}.stamp" file)"
    [[ -n "$f" ]] && printf '    %-8s %s\n' "${o}:" "$f"
  done
  for o in "${SKIPPED_OUTPUTS[@]}"; do printf '    %-8s %s\n' "${o}:" "not made for ${ARCH_NAME} (see the warning above)"; done
  info "Log:     ${S[LOG_PATH]} (steps: ${LOG_DIR})"
}

# --image-setup: in a new container of a base image, as root: install every package group this distribution has
# (build, runtime, tests, appimage and its package format), so the image builds any combination of outputs.
image_setup_main() {
  resolve_settings "$ARCH_BUILD"
  detect_distro
  [[ -n "$PM" ]] || die "${DISTRO_NAME}: no known package manager (apt, dnf, pacman, zypper); choose another base image (CONTAINER_IMAGES)"
  S[TESTS]=ON OPT_INSTALL_DEPS=1 OPT_YES=1 OPT_VERBOSE=1
  OUTPUTS=(install appimage); [[ -n "$NATIVE_PKG" ]] && OUTPUTS+=("$NATIVE_PKG")
  info "${ARCH_NAME} image on ${DISTRO_NAME}"
  resolve_packages
  ensure_packages
  case "$PM" in
    apt) apt-get clean ;;
    dnf) dnf clean all >/dev/null 2>&1 || true ;;
    zypper) zypper clean -a >/dev/null 2>&1 || true ;;
    pacman) yes | pacman -Scc >/dev/null 2>&1 || true ;;
  esac
}

main "$@"; exit
