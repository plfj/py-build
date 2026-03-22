#!/usr/bin/env bash
# =============================================================================
# Termux Python 3.14.3 — prepare-source.sh
# =============================================================================
# PART 1 OF 2: Download CPython + debpython, apply all Termux patches,
# run autoreconf -fi to regenerate the configure script from the patched
# configure.ac, then pack the result into a ready-to-configure tarball
# (python-3.14.3-patched-src.tar.xz) for upload to the GitHub release.
#
# Usage:
#   bash prepare-source.sh [--clean] [--skip-verify] [--jobs N]
#
# Requires: autoconf 2.71+, automake, m4, patch, curl/wget, tar
# Output  : python-3.14.3-patched-src.tar.xz   (in $OUTPUT_DIR)
#
# Patch files must be present in a patches/ directory alongside this script.
# =============================================================================
set -euo pipefail

# =============================================================================
# §0  SCRIPT IDENTITY
# =============================================================================
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly _SCRIPT_DIR
readonly _PATCH_DIR="${_SCRIPT_DIR}/patches"
tmp=""

# =============================================================================
# §1  PACKAGE CONSTANTS
# =============================================================================
readonly TERMUX_PKG_VERSION="3.14.3"
readonly TERMUX_PKG_REVISION=0
readonly _MAJOR_VERSION="${TERMUX_PKG_VERSION%.*}"   # -> "3.14"
readonly _DEBPYTHON_COMMIT="f358ab52bf2932ad55b1a72a29c9762169e6ac47"

# =============================================================================
# §2  SOURCE URLs + SHA256
# =============================================================================
readonly _PYTHON_URL="https://www.python.org/ftp/python/${TERMUX_PKG_VERSION}/Python-${TERMUX_PKG_VERSION}.tar.xz"
readonly _PYTHON_SHA256="a97d5549e9ad81fe17159ed02c68774ad5d266c72f8d9a0b5a9c371fe85d902b"

readonly _DEBPYTHON_URL="https://salsa.debian.org/cpython-team/python3-defaults/-/archive/${_DEBPYTHON_COMMIT}/python3-defaults-${_DEBPYTHON_COMMIT}.tar.gz"
readonly _DEBPYTHON_SHA256="3b7a76c144d39f5c4a2c7789fd4beb3266980c2e667ad36167e1e7a357c684b0"

# Output tarball name (also used by build.sh to know what to download)
readonly _OUTPUT_TARBALL="python-${TERMUX_PKG_VERSION}-patched-src.tar.xz"

# =============================================================================
# §3  REQUIRED PATCH FILES (in apply order; 0012 handled separately)
# =============================================================================
readonly -a _PATCH_FILES=(
    "0001-fix-hardcoded-paths.patch"
    "0002-no-setuid-servers.patch"
    "0003-ctypes-util-use-llvm-tools.patch"
    "0004-impl-getprotobyname.patch"
    "0005-impl-multiprocessing.patch"
    "0006-disable-multiarch.patch"
    "0007-do-not-use-link.patch"
    "0008-fix-pkgconfig-variable-substitution.patch"
    "0009-fix-ctypes-util-find_library.patch"
    "0010-do-not-hardlink.patch"
    "0011-fix-module-linking.patch"
    "0012-hardcode-android-api-level.diff"
    "0013-backport-sysconfig-patch-for-32-bit-on-64-bit-arm-kernel.patch"
    "debpython.patch"
)

# =============================================================================
# §4  OPTION VARIABLES
# =============================================================================
_OPT_CLEAN=false
_OPT_JOBS=""
# API level needed only for 0012 substitution
_OPT_API_LEVEL="${TERMUX_PKG_API_LEVEL:-35}"
# Where to write the output tarball
OUTPUT_DIR="${OUTPUT_DIR:-${_SCRIPT_DIR}/dist}"
mkdir -p "$OUTPUT_DIR"

# =============================================================================
# §5  LOGGING
# =============================================================================
if [[ -t 2 ]]; then
    _C_RST='\033[0m'  _C_BLU='\033[1;34m' _C_GRN='\033[1;32m'
    _C_YLW='\033[1;33m' _C_RED='\033[1;31m' _C_CYN='\033[1;36m'
else
    _C_RST='' _C_BLU='' _C_GRN='' _C_YLW='' _C_RED='' _C_CYN=''
fi
_info()    { printf "${_C_BLU}[INFO]${_C_RST}   %s\n"  "$*";     }
_ok()      { printf "${_C_GRN}[ OK ]${_C_RST}   %s\n"  "$*";     }
_warn()    { printf "${_C_YLW}[WARN]${_C_RST}   %s\n"  "$*" >&2; }
_error()   { printf "${_C_RED}[ERR ]${_C_RST}   %s\n"  "$*" >&2; }
_die()     { _error "$*"; exit 1;                                  }
_section() {
    local line="══════════════════════════════════════════════════════════════"
    printf "\n${_C_CYN}%s\n  %s\n%s${_C_RST}\n\n" "$line" "$*" "$line"
}

# =============================================================================
# §6  ARGUMENT PARSING
# =============================================================================
_parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --help|-h)
                grep '^# ' "$0" | head -20 | sed 's/^# \{0,2\}//'
                exit 0 ;;
            --clean)        _OPT_CLEAN=true ;;
            --api-level)
                [[ -n "${2:-}" ]] || _die "--api-level requires a numeric argument"
                _OPT_API_LEVEL="$2"; shift ;;
            --jobs|-j)
                [[ -n "${2:-}" ]] || _die "--jobs requires a numeric argument"
                [[ "$2" =~ ^[1-9][0-9]*$ ]] || _die "--jobs must be a positive integer"
                _OPT_JOBS="$2"; shift ;;
            --output-dir)
                [[ -n "${2:-}" ]] || _die "--output-dir requires a path"
                OUTPUT_DIR="$2"; shift ;;
            *) _die "Unknown option: '$1'  (try --help)" ;;
        esac
        shift
    done
}

# =============================================================================
# §7  ENVIRONMENT SETUP
# =============================================================================
_setup_env() {
    TERMUX_PKG_API_LEVEL="${_OPT_API_LEVEL}"
    export TERMUX_PKG_API_LEVEL

    WORKDIR="${TMPDIR:-/tmp}/python-prepare"
    SRCDIR="${WORKDIR}/src"
    CACHEDIR="${WORKDIR}/cache"

    if [[ -n "${_OPT_JOBS}" ]]; then
        JOBS="${_OPT_JOBS}"
    elif [[ "$(uname)" == "Darwin" ]]; then
        JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
    else
        JOBS="$(nproc 2>/dev/null || echo 1)"
    fi
}

# =============================================================================
# §8  SHA256 + DOWNLOAD
# =============================================================================
_sha256() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        _die "No SHA-256 utility found. Install sha256sum or shasum."
    fi
}

_download() {
    local url="$1" dest="$2" expected="$3"
    # Declare tmp before any early return so the trap never fires on an
    # unbound variable (set -u would error if trap fires before assignment).
    local tmp="${dest}.tmp.$$"
    trap 'rm -f "$tmp"' RETURN INT TERM

    mkdir -p "$(dirname "$dest")"
    if [[ -f "$dest" ]]; then
        local actual; actual="$(_sha256 "$dest")"
        if [[ "$actual" == "$expected" ]]; then
            _ok "Cache hit: $(basename "$dest")"; return 0
        fi
        _warn "SHA256 mismatch on cached file — re-downloading"
        rm -f "$dest"
    fi
    _info "Downloading: $(basename "$dest")"
    if command -v curl &>/dev/null; then
        curl -fL --retry 5 --retry-delay 2 --connect-timeout 30 \
             --progress-bar -o "$tmp" "$url" || _die "curl failed: $url"
    else
        wget --tries=5 --timeout=30 -q --show-progress \
             -O "$tmp" "$url" || _die "wget failed: $url"
    fi
    local actual; actual="$(_sha256 "$tmp")"
    [[ "$actual" == "$expected" ]] || {
        rm -f "$tmp"
        _error "SHA256 mismatch: expected=$expected got=$actual"
        _die "Download integrity check failed."
    }
    mv "$tmp" "$dest"
    _ok "Downloaded: $(basename "$dest")"
}

# =============================================================================
# §9  TOOL CHECK
# =============================================================================
_check_tools() {
    _info "Checking required tools ..."
    local missing=0
    for t in patch tar m4 automake; do
        command -v "$t" &>/dev/null || { _error "Missing: $t"; (( missing++ )) || true; }
    done
    if ! command -v autoreconf &>/dev/null; then
        _error "Missing: autoreconf"
        (( missing++ )) || true
    fi
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        _error "Missing: curl or wget"
        (( missing++ )) || true
    fi

    # Python 3.14 requires autoconf >= 2.71 for the new configure.ac macros.
    # Warn (don't die) so that CI environments with 2.69 can still attempt a
    # build — some patches may compensate — but the warning is important.
    if command -v autoconf &>/dev/null; then
        local _ac_ver
        _ac_ver="$(autoconf --version | head -1 | grep -oE '[0-9]+\.[0-9]+')"
        local _ac_maj _ac_min
        _ac_maj="${_ac_ver%%.*}"
        _ac_min="${_ac_ver#*.}"
        if (( _ac_maj < 2 )) || { (( _ac_maj == 2 )) && (( _ac_min < 71 )); }; then
            _warn "autoconf ${_ac_ver} detected — Python 3.14 requires >= 2.71."
            _warn "Build may fail. Consider: apt install autoconf=2.71 or use the"
            _warn "Termux build container which ships a compatible version."
        else
            _ok "autoconf ${_ac_ver} (>= 2.71 required — OK)"
        fi
    fi

    (( missing > 0 )) && _die "${missing} required tool(s) missing."
    _ok "All required tools present."
}

# =============================================================================
# §10  PATCH VALIDATION
# =============================================================================
_validate_patches() {
    _info "Validating patch files in: $_PATCH_DIR"
    local missing=0
    for f in "${_PATCH_FILES[@]}"; do
        local p="${_PATCH_DIR}/${f}"
        [[ -f "$p" ]] || { _error "Missing: patches/${f}"; (( missing++ )) || true; }
        [[ -s "$p" ]] || { _error "Empty:   patches/${f}"; (( missing++ )) || true; }
    done
    (( missing > 0 )) && _die "${missing} patch file(s) missing or empty."
    _ok "All ${#_PATCH_FILES[@]} patch files present."
}

# =============================================================================
# §11  APPLY PATCHES
# =============================================================================
_apply_0012() {
    local patch="${_PATCH_DIR}/0012-hardcode-android-api-level.diff"
    _info "Applying 0012 with API_LEVEL=${TERMUX_PKG_API_LEVEL} ..."
    sed -e "s%@TERMUX_PKG_API_LEVEL@%${TERMUX_PKG_API_LEVEL}%g" "$patch" \
        | patch --silent -p1 \
        || _die "Failed to apply 0012"
    _ok "Applied: 0012-hardcode-android-api-level.diff"
}

_apply_patches() {
    _info "Applying patches (0012 already applied) ..."
    local -a files=()
    for _p in "${_PATCH_DIR}"/*.patch "${_PATCH_DIR}"/*.diff; do
        [[ -f "$_p" ]] && files+=("$_p")
    done
    IFS=$'\n' read -r -d '' -a files \
        < <(printf '%s\n' "${files[@]}" | sort && printf '\0') || true

    local applied=0 skipped=0
    for p in "${files[@]}"; do
        local name; name="$(basename "$p")"
        if [[ "$name" == *"hardcode-android-api-level"* ]]; then
            _info "Skipping (pre-applied): $name"
            (( skipped++ )) || true; continue
        fi
        _info "Applying: $name"
        patch -p1 --silent < "$p" || _die "Failed to apply: $name"
        (( applied++ )) || true
    done
    _ok "Patches applied: ${applied}  (skipped: ${skipped})"
}

# =============================================================================
# §12  AUTORECONF
# =============================================================================
_run_autoreconf() {
    cd "$SRCDIR"

    # Resolve binaries — prefer explicit env vars (set by CI when using a
    # custom-built autoconf), fall back to PATH lookup.
    local _autoconf_bin _autoreconf_bin
    _autoconf_bin="${AUTOCONF:-$(command -v autoconf)}"
    _autoreconf_bin="${AUTORECONF:-$(command -v autoreconf)}"

    [[ -x "$_autoconf_bin"   ]] || _die "autoconf not found (tried: $_autoconf_bin)"
    [[ -x "$_autoreconf_bin" ]] || _die "autoreconf not found (tried: $_autoreconf_bin)"

    local _ac_ver
    _ac_ver="$("$_autoconf_bin" --version | head -1 | grep -oE '[0-9]+\.[0-9]+')"
    _info "Running autoreconf -fi (autoconf ${_ac_ver} at ${_autoconf_bin}) ..."

    # Derive the real bin directory from the resolved absolute path.
    # Using 'command -v' guarantees we get an absolute path even when the
    # binary is on PATH as a bare name (as it is inside the CPython container).
    local _ac_bindir
    _ac_bindir="$(dirname "$(command -v "$_autoconf_bin")")"
    local _ac_prefix="${_ac_bindir%/bin}"

    local _ac_datadir="${AUTOCONF_DATADIR:-${_ac_prefix}/share/autoconf}"
    local _aclocal_dir="${_ac_prefix}/share/aclocal"

    AUTOCONF="${_autoconf_bin}" \
    AUTOHEADER="${AUTOHEADER:-${_ac_bindir}/autoheader}" \
    AUTOM4TE="${AUTOM4TE:-${_ac_bindir}/autom4te}" \
    ACLOCAL_PATH="${_aclocal_dir}" \
        "$_autoreconf_bin" -fi

    _ok "autoreconf complete (autoconf ${_ac_ver})."
}

# =============================================================================
# §13  DEBPYTHON RENAME + PLACEHOLDER SUBSTITUTION
# =============================================================================
_setup_debpython() {
    local unpacked="${SRCDIR}/python3-defaults-${_DEBPYTHON_COMMIT}"
    if [[ -d "$unpacked" ]]; then
        mv "$unpacked" "${SRCDIR}/debpython"
        _ok "Renamed python3-defaults -> debpython"
    elif [[ ! -d "${SRCDIR}/debpython" ]]; then
        _die "debpython directory not found after unpack."
    fi

    local fullver="${TERMUX_PKG_VERSION}-${TERMUX_PKG_REVISION}"
    local count=0
    while IFS= read -r -d '' file; do
        if sed --version 2>&1 | grep -q GNU; then
            sed -i \
                -e "s|@TERMUX_PYTHON_VERSION@|${_MAJOR_VERSION}|g" \
                -e "s|@TERMUX_PKG_FULLVERSION@|${fullver}|g" \
                "$file"
        else
            sed -i '' \
                -e "s|@TERMUX_PYTHON_VERSION@|${_MAJOR_VERSION}|g" \
                -e "s|@TERMUX_PKG_FULLVERSION@|${fullver}|g" \
                "$file"
        fi
        (( count++ )) || true
    done < <(find "${SRCDIR}/debpython" -type f -print0)
    _ok "debpython: substituted version placeholders in ${count} file(s)."
}

# =============================================================================
# §14  PACK OUTPUT TARBALL
# =============================================================================
_pack_source() {
    mkdir -p "$OUTPUT_DIR"
    local out="${OUTPUT_DIR}/${_OUTPUT_TARBALL}"
    _info "Packing patched source tree -> ${_OUTPUT_TARBALL} ..."
    # Pack the entire SRCDIR as a single top-level directory "python-src"
    # so build.sh can extract it with --strip-components=1 directly into its own srcdir.
    tar -C "$(dirname "$SRCDIR")" \
        -cJf "$out" \
        --transform "s|^$(basename "$SRCDIR")|python-src|" \
        "$(basename "$SRCDIR")"
    local size; size="$(du -sh "$out" | cut -f1)"
    _ok "Packed: ${out}  (${size})"
}

# =============================================================================
# §15  MAIN
# =============================================================================
main() {
    _parse_args "$@"
    _setup_env

    _section "Termux Python ${TERMUX_PKG_VERSION} — Prepare Source"
    printf "  %-16s %s\n" "Version:"    "${TERMUX_PKG_VERSION} (rev ${TERMUX_PKG_REVISION})"
    printf "  %-16s %s\n" "API Level:"  "${TERMUX_PKG_API_LEVEL}"
    printf "  %-16s %s\n" "Output:"     "${OUTPUT_DIR}/${_OUTPUT_TARBALL}"
    printf "  %-16s %s\n" "Workdir:"    "${WORKDIR}"
    printf "  %-16s %s\n" "Jobs:"       "${JOBS}"
    echo

    _section "Step 1/7 — Tool Check"
    _check_tools

    _section "Step 2/7 — Patch Validation"
    _validate_patches

    if [[ "$_OPT_CLEAN" == "true" ]]; then
        _info "Removing workdir: $WORKDIR"
        rm -rf "$WORKDIR"
    fi
    mkdir -p "$CACHEDIR" "$SRCDIR"

    _section "Step 3/7 — Download Sources"
    # Python 3.14 ships .tar.xz only (no .tgz); unpack with -xJf below.
    _download "$_PYTHON_URL" \
        "${CACHEDIR}/Python-${TERMUX_PKG_VERSION}.tar.xz" \
        "$_PYTHON_SHA256"
    _download "$_DEBPYTHON_URL" \
        "${CACHEDIR}/python3-defaults-${_DEBPYTHON_COMMIT}.tar.gz" \
        "$_DEBPYTHON_SHA256"

    _section "Step 4/7 — Unpack"
    _info "Unpacking Python-${TERMUX_PKG_VERSION}.tar.xz ..."
    rm -rf "$SRCDIR"
    mkdir -p "$SRCDIR"
    tar -xJf "${CACHEDIR}/Python-${TERMUX_PKG_VERSION}.tar.xz" \
        --strip-components=1 -C "$SRCDIR" \
        || _die "Failed to unpack Python tarball."
    _ok "CPython source unpacked."

    _info "Unpacking python3-defaults tarball ..."
    tar -xf "${CACHEDIR}/python3-defaults-${_DEBPYTHON_COMMIT}.tar.gz" \
        -C "$SRCDIR" || _die "Failed to unpack python3-defaults."
    _ok "python3-defaults unpacked."

    _section "Step 5/7 — Apply Patches"
    cd "$SRCDIR"
    _apply_0012
    _setup_debpython
    _apply_patches

    _section "Step 6/7 — autoreconf -fi"
    _run_autoreconf

    _section "Step 7/7 — Pack Patched Source"
    _pack_source

    _section "Done"
    printf "  Upload to GitHub release:\n"
    printf "  %s\n\n" "${OUTPUT_DIR}/${_OUTPUT_TARBALL}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
