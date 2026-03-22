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
#   bash prepare-source.sh [OPTIONS]
#
# Options:
#   -h, --help              Show this help and exit
#       --clean             Wipe workdir before starting
#       --skip-autoreconf   Skip the autoreconf -fi step (useful when iterating
#                           on patches only, assuming configure.ac is unchanged)
#       --dry-run           Download and validate patches but do not apply them
#                           or pack the tarball; useful for CI pre-flight checks
#       --no-pack           Apply patches and run autoreconf but skip tarball
#                           creation; useful for local source inspection
#       --verify-patches    Run patch --dry-run on every patch before applying
#                           and abort if any would fail (strict mode)
#       --keep-workdir      Preserve the workdir even if --clean is set; useful
#                           to keep the patched source tree for inspection after
#                           the tarball is built
#       --api-level N       Android API level to substitute into 0012
#                           (default: $TERMUX_PKG_API_LEVEL or 35)
#       --jobs N            Override parallel job count
#       --output-dir PATH   Where to write the output tarball
#                           (default: $OUTPUT_DIR or ./dist)
#       --patch-dir PATH    Directory containing patch files
#                           (default: ./patches next to this script)
#       --workdir PATH      Override the working directory
#                           (default: $TMPDIR/python-prepare-3.14.3)
#
# Environment variables (all have flag equivalents above):
#   TERMUX_PKG_API_LEVEL    Android API level (default: 35)
#   OUTPUT_DIR              Where to write the output tarball
#   TERMUX_PATCH_DIR        Directory containing patch files
#   AUTOCONF / AUTORECONF   Override autoconf / autoreconf binary paths
#   AUTOHEADER / AUTOM4TE   Override autoheader / autom4te binary paths
#
# Output:
#   dist/python-3.14.3-patched-src.tar.xz
#   dist/python-3.14.3-patched-src.tar.xz.sha256
#
# Requirements:
#   autoconf >= 2.71, automake, m4, patch, curl or wget, tar, xz
# =============================================================================
set -euo pipefail

# =============================================================================
# §0  SCRIPT IDENTITY & ERROR TRAPPING
# =============================================================================
_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
_SCRIPT_DIR="$(dirname "$_SCRIPT_PATH")"
readonly _SCRIPT_PATH _SCRIPT_DIR

_err_trap() {
    local code=$? line="${BASH_LINENO[0]:-?}"
    printf '\n\033[1;31m[FATAL]\033[0m  prepare-source.sh aborted at line %s (exit %s)\n' \
        "$line" "$code" >&2
    exit "$code"
}
trap '_err_trap' ERR

# =============================================================================
# §1  PACKAGE CONSTANTS  (keep in sync with build-pkg.sh)
# =============================================================================
readonly TERMUX_PKG_VERSION="3.14.3"
readonly TERMUX_PKG_REVISION=0
readonly _MAJOR_VERSION="${TERMUX_PKG_VERSION%.*}"        # 3.14
readonly _DEBPYTHON_COMMIT="f358ab52bf2932ad55b1a72a29c9762169e6ac47"
readonly _OUTPUT_TARBALL="python-${TERMUX_PKG_VERSION}-patched-src.tar.xz"

# =============================================================================
# §2  SOURCE URLs + SHA256
# =============================================================================
readonly _PYTHON_URL="https://www.python.org/ftp/python/${TERMUX_PKG_VERSION}/Python-${TERMUX_PKG_VERSION}.tar.xz"
readonly _PYTHON_SHA256="a97d5549e9ad81fe17159ed02c68774ad5d266c72f8d9a0b5a9c371fe85d902b"

readonly _DEBPYTHON_URL="https://salsa.debian.org/cpython-team/python3-defaults/-/archive/${_DEBPYTHON_COMMIT}/python3-defaults-${_DEBPYTHON_COMMIT}.tar.gz"
readonly _DEBPYTHON_SHA256="3b7a76c144d39f5c4a2c7789fd4beb3266980c2e667ad36167e1e7a357c684b0"

# =============================================================================
# §3  REQUIRED PATCH FILES  (applied in this exact order; 0012 is pre-applied)
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
_OPT_SKIP_AUTORECONF=false
_OPT_DRY_RUN=false
_OPT_NO_PACK=false
_OPT_VERIFY_PATCHES=false
_OPT_KEEP_WORKDIR=false
_OPT_API_LEVEL="${TERMUX_PKG_API_LEVEL:-35}"
_OPT_JOBS=""
_OPT_OUTPUT_DIR="${OUTPUT_DIR:-${_SCRIPT_DIR}/dist}"
_OPT_PATCH_DIR="${TERMUX_PATCH_DIR:-${_SCRIPT_DIR}/patches}"
_OPT_WORKDIR=""

# =============================================================================
# §5  LOGGING  (timestamped, colour-aware)
# =============================================================================
if [[ -t 2 ]]; then
    _CR='\033[0m' _BLU='\033[1;34m' _GRN='\033[1;32m'
    _YLW='\033[1;33m' _RED='\033[1;31m' _CYN='\033[1;36m' _MAG='\033[1;35m'
else
    _CR='' _BLU='' _GRN='' _YLW='' _RED='' _CYN='' _MAG=''
fi

_ts()      { date '+%H:%M:%S'; }
_info()    { printf "${_BLU}[%s INFO ]${_CR}  %s\n"  "$(_ts)" "$*";     }
_ok()      { printf "${_GRN}[%s  OK  ]${_CR}  %s\n"  "$(_ts)" "$*";     }
_warn()    { printf "${_YLW}[%s WARN ]${_CR}  %s\n"  "$(_ts)" "$*" >&2; }
_error()   { printf "${_RED}[%s ERROR]${_CR}  %s\n"  "$(_ts)" "$*" >&2; }
_step()    { printf "${_MAG}[%s STEP ]${_CR}  %s\n"  "$(_ts)" "$*";     }
_die()     { _error "$*"; exit 1;                                         }
_dry()     { printf "${_YLW}[%s  DRY ]${_CR}  (skipped) %s\n" "$(_ts)" "$*"; }
_section() {
    local sep="══════════════════════════════════════════════════════════════"
    printf "\n${_CYN}%s\n  %s\n%s${_CR}\n\n" "$sep" "$*" "$sep"
}

# =============================================================================
# §6  ARGUMENT PARSING
# =============================================================================
_parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                sed -n '/^# Usage:/,/^# ====/{ /^# ====/d; s/^# \{0,2\}//; p }' "$_SCRIPT_PATH"
                exit 0 ;;
            --clean)               _OPT_CLEAN=true ;;
            --skip-autoreconf)     _OPT_SKIP_AUTORECONF=true ;;
            --dry-run)             _OPT_DRY_RUN=true ;;
            --no-pack)             _OPT_NO_PACK=true ;;
            --verify-patches)      _OPT_VERIFY_PATCHES=true ;;
            --keep-workdir)        _OPT_KEEP_WORKDIR=true ;;
            --api-level)
                [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]] \
                    || _die "--api-level requires a numeric argument"
                _OPT_API_LEVEL="$2"; shift ;;
            --jobs|-j)
                [[ -n "${2:-}" && "$2" =~ ^[1-9][0-9]*$ ]] \
                    || _die "--jobs requires a positive integer"
                _OPT_JOBS="$2"; shift ;;
            --output-dir)
                [[ -n "${2:-}" ]] || _die "--output-dir requires a path"
                _OPT_OUTPUT_DIR="$2"; shift ;;
            --patch-dir)
                [[ -n "${2:-}" ]] || _die "--patch-dir requires a path"
                _OPT_PATCH_DIR="$2"; shift ;;
            --workdir)
                [[ -n "${2:-}" ]] || _die "--workdir requires a path"
                _OPT_WORKDIR="$2"; shift ;;
            *) _die "Unknown option: '$1'  (try --help)" ;;
        esac
        shift
    done
}

# =============================================================================
# §7  ENVIRONMENT SETUP
# =============================================================================
_setup_env() {
    export TERMUX_PKG_API_LEVEL="${_OPT_API_LEVEL}"

    if [[ -n "$_OPT_WORKDIR" ]]; then
        WORKDIR="$_OPT_WORKDIR"
    else
        WORKDIR="${TMPDIR:-/tmp}/python-prepare-${TERMUX_PKG_VERSION}"
    fi
    SRCDIR="${WORKDIR}/src"
    CACHEDIR="${WORKDIR}/cache"
    LOGDIR="${WORKDIR}/logs"
    readonly WORKDIR SRCDIR CACHEDIR LOGDIR

    OUTPUT_DIR="$_OPT_OUTPUT_DIR"
    PATCH_DIR="$_OPT_PATCH_DIR"
    readonly OUTPUT_DIR PATCH_DIR

    if [[ -n "${_OPT_JOBS}" ]]; then
        JOBS="${_OPT_JOBS}"
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    else
        JOBS="$(nproc 2>/dev/null || echo 4)"
    fi
    export JOBS
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
        _die "No SHA-256 tool found. Install coreutils (sha256sum) or shasum."
    fi
}

_download() {
    local url="$1" dest="$2" expected="${3:-}"
    local tmp="${dest}.tmp.$$"
    local name; name="$(basename "$dest")"

    mkdir -p "$(dirname "$dest")"

    if [[ -f "$dest" ]]; then
        if [[ -z "$expected" ]]; then
            _ok "Cache hit (no checksum): $name"; return 0
        fi
        local actual; actual="$(_sha256 "$dest")"
        if [[ "$actual" == "$expected" ]]; then
            _ok "Cache hit (verified): $name"; return 0
        fi
        _warn "Cache checksum mismatch — re-downloading $name"
        _warn "  expected: $expected"
        _warn "  got:      $actual"
        rm -f "$dest"
    fi

    _info "Downloading: $name"
    _info "  URL: $url"

    local -a dl_cmd=()
    if command -v curl &>/dev/null; then
        dl_cmd=(curl --fail --location --retry 5 --retry-delay 3
                     --retry-all-errors --connect-timeout 30
                     --progress-bar --output "$tmp" -- "$url")
    elif command -v wget &>/dev/null; then
        dl_cmd=(wget --tries=5 --timeout=30 --waitretry=3
                     --show-progress --quiet --output-document="$tmp" -- "$url")
    else
        _die "Neither curl nor wget found."
    fi

    if ! "${dl_cmd[@]}"; then
        rm -f "$tmp"; _die "Download failed: $url"
    fi

    if [[ -n "$expected" ]]; then
        local actual; actual="$(_sha256 "$tmp")"
        if [[ "$actual" != "$expected" ]]; then
            rm -f "$tmp"
            _error "SHA256 mismatch for $name"
            _error "  expected: $expected"
            _error "  got:      $actual"
            _die "Download integrity check failed."
        fi
    fi

    mv "$tmp" "$dest"
    _ok "Downloaded: $name  ($(du -sh "$dest" | cut -f1))"
}

# =============================================================================
# §9  TOOL CHECK
# =============================================================================
_require_tool() {
    local tool="$1" hint="${2:-}"
    if ! command -v "$tool" &>/dev/null; then
        _error "Required tool not found: $tool"
        [[ -n "$hint" ]] && _error "  Install hint: $hint"
        return 1
    fi
    _info "  OK: $tool → $(command -v "$tool")"
    return 0
}

_check_tools() {
    _info "Checking required tools ..."
    local missing=0

    _require_tool patch    "apt install patch / brew install gpatch"      || (( missing++ )) || true
    _require_tool tar      "apt install tar"                               || (( missing++ )) || true
    _require_tool xz       "apt install xz-utils / brew install xz"       || (( missing++ )) || true
    _require_tool m4       "apt install m4 / brew install m4"             || (( missing++ )) || true
    _require_tool automake "apt install automake / brew install automake"  || (( missing++ )) || true

    if ! _require_tool autoreconf "apt install autoconf / brew install autoconf"; then
        (( missing++ )) || true
    else
        # Python 3.14 requires autoconf >= 2.71
        local _ac_ver
        _ac_ver="$(autoconf --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+')"
        local _ac_maj="${_ac_ver%%.*}" _ac_min="${_ac_ver#*.}"
        if (( _ac_maj < 2 )) || { (( _ac_maj == 2 )) && (( _ac_min < 71 )); }; then
            _error "autoconf ${_ac_ver} is too old — Python 3.14 requires >= 2.71"
            _error "  Use the CPython autoconf container:"
            _error "    ghcr.io/python/autoconf:2024.10.16.11360930377"
            (( missing++ )) || true
        else
            _ok "  autoconf ${_ac_ver} (>= 2.71 — OK)"
        fi
    fi

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        _error "Required: curl or wget"
        (( missing++ )) || true
    else
        command -v curl &>/dev/null && _info "  OK: curl → $(command -v curl)"
        command -v wget &>/dev/null && _info "  OK: wget → $(command -v wget)"
    fi

    [[ "$missing" -ne 0 ]] && _die "${missing} required tool(s) missing."
    _ok "All required tools present."
}

# =============================================================================
# §10  PATCH VALIDATION + OPTIONAL DRY-RUN VERIFICATION
# =============================================================================
_validate_patches() {
    _info "Validating patch files in: $PATCH_DIR"
    local missing=0

    for f in "${_PATCH_FILES[@]}"; do
        local p="${PATCH_DIR}/${f}"
        if [[ ! -f "$p" ]]; then
            _error "Missing patch: patches/${f}"; (( missing++ )) || true
        elif [[ ! -s "$p" ]]; then
            _error "Empty patch:   patches/${f}"; (( missing++ )) || true
        else
            _info "  OK: $f  ($(wc -l < "$p" | tr -d ' ') lines)"
        fi
    done

    [[ "$missing" -ne 0 ]] && _die "${missing} patch file(s) missing or empty."
    _ok "All ${#_PATCH_FILES[@]} patch files present and non-empty."
}

_verify_patches_dryrun() {
    [[ "$_OPT_VERIFY_PATCHES" == "true" ]] || return 0
    [[ "$_OPT_DRY_RUN"        != "true" ]] || return 0   # nothing to verify in dry-run

    _info "Running patch --dry-run on all patches (--verify-patches) ..."
    local failed=0
    cd "$SRCDIR"

    for f in "${_PATCH_FILES[@]}"; do
        local p="${PATCH_DIR}/${f}"
        local name; name="$(basename "$p")"
        local patch_input="$p"
        local tmp_subst=""

        # 0012 needs the @TERMUX_PKG_API_LEVEL@ placeholder substituted first
        if [[ "$name" == *"hardcode-android-api-level"* ]]; then
            tmp_subst="$(mktemp)"
            sed -e "s%@TERMUX_PKG_API_LEVEL@%${TERMUX_PKG_API_LEVEL}%g" \
                "$p" > "$tmp_subst"
            patch_input="$tmp_subst"
        fi

        if patch --dry-run -p1 --silent < "$patch_input" 2>/dev/null; then
            _ok "  dry-run OK: $name"
        else
            _error "  dry-run FAIL: $name"
            patch --dry-run -p1 < "$patch_input" 2>&1 | head -25 >&2 || true
            (( failed++ )) || true
        fi

        [[ -n "$tmp_subst" ]] && rm -f "$tmp_subst"
    done

    [[ "$failed" -ne 0 ]] && \
        _die "${failed} patch(es) failed dry-run — fix context mismatches before applying."
    _ok "All patches passed dry-run verification."
}

# =============================================================================
# §11  APPLY PATCHES
# =============================================================================

# 0012 patches Lib/platform.py: replaces the runtime getprop() call for
# ro.build.version.sdk with a compile-time integer so that platform.android_ver()
# reports the correct API level without querying system properties at runtime.
_apply_0012() {
    local patch="${PATCH_DIR}/0012-hardcode-android-api-level.diff"
    _info "Applying 0012 — substituting @TERMUX_PKG_API_LEVEL@ → ${TERMUX_PKG_API_LEVEL}"

    if [[ "$_OPT_DRY_RUN" == "true" ]]; then
        _dry "Would apply 0012 with API_LEVEL=${TERMUX_PKG_API_LEVEL}"; return 0
    fi

    local log="${LOGDIR}/patch-0012.log"
    sed -e "s%@TERMUX_PKG_API_LEVEL@%${TERMUX_PKG_API_LEVEL}%g" "$patch" \
        | patch -p1 --verbose > "$log" 2>&1 \
        || { cat "$log" >&2; _die "Failed to apply 0012 — see: $log"; }
    _ok "Applied: 0012-hardcode-android-api-level.diff"
}

_apply_patches() {
    _info "Applying patches ..."
    local applied=0 skipped=0

    for f in "${_PATCH_FILES[@]}"; do
        local p="${PATCH_DIR}/${f}"
        local name; name="$(basename "$p")"

        # 0012 was already handled by _apply_0012()
        if [[ "$name" == *"hardcode-android-api-level"* ]]; then
            _info "  Skipping (already applied): $name"
            (( skipped++ )) || true; continue
        fi

        if [[ "$_OPT_DRY_RUN" == "true" ]]; then
            _dry "Would apply: $name"; (( applied++ )) || true; continue
        fi

        _info "  Applying: $name"
        local log="${LOGDIR}/patch-${name}.log"
        patch -p1 --verbose < "$p" > "$log" 2>&1 \
            || { cat "$log" >&2; _die "Failed to apply: $name — see: $log"; }
        _ok "  Applied: $name"
        (( applied++ )) || true
    done

    _ok "Patches applied: ${applied}  (skipped: ${skipped})"
}

# =============================================================================
# §12  AUTORECONF
# =============================================================================
_run_autoreconf() {
    if [[ "$_OPT_SKIP_AUTORECONF" == "true" ]]; then
        _warn "Skipping autoreconf (--skip-autoreconf set)."; return 0
    fi
    if [[ "$_OPT_DRY_RUN" == "true" ]]; then
        _dry "Would run: autoreconf -fi in $SRCDIR"; return 0
    fi

    cd "$SRCDIR"

    local _autoconf_bin _autoreconf_bin
    _autoconf_bin="${AUTOCONF:-$(command -v autoconf)}"
    _autoreconf_bin="${AUTORECONF:-$(command -v autoreconf)}"

    [[ -x "$_autoconf_bin"   ]] || _die "autoconf not executable: $_autoconf_bin"
    [[ -x "$_autoreconf_bin" ]] || _die "autoreconf not executable: $_autoreconf_bin"

    local _ac_ver
    _ac_ver="$("$_autoconf_bin" --version | head -1 | grep -oE '[0-9]+\.[0-9]+')"
    _info "Running autoreconf -fi  (autoconf ${_ac_ver})"

    local _ac_bindir; _ac_bindir="$(dirname "$(command -v "$_autoconf_bin")")"
    local _ac_prefix="${_ac_bindir%/bin}"
    local _aclocal_dir="${_ac_prefix}/share/aclocal"

    local log="${LOGDIR}/autoreconf.log"
    _info "  Log: $log"

    AUTOCONF="${_autoconf_bin}" \
    AUTOHEADER="${AUTOHEADER:-${_ac_bindir}/autoheader}" \
    AUTOM4TE="${AUTOM4TE:-${_ac_bindir}/autom4te}" \
    ACLOCAL_PATH="${_aclocal_dir}" \
        "$_autoreconf_bin" -fi 2>&1 | tee "$log" \
        || _die "autoreconf -fi failed — see: $log"

    _ok "autoreconf complete (autoconf ${_ac_ver})."
}

# =============================================================================
# §13  DEBPYTHON: RENAME + PLACEHOLDER SUBSTITUTION + RESIDUE CHECK
# =============================================================================
_setup_debpython() {
    if [[ "$_OPT_DRY_RUN" == "true" ]]; then
        _dry "Would set up debpython directory"; return 0
    fi

    local unpacked="${SRCDIR}/python3-defaults-${_DEBPYTHON_COMMIT}"
    if [[ -d "$unpacked" ]]; then
        mv "$unpacked" "${SRCDIR}/debpython"
        _ok "Renamed python3-defaults → debpython"
    elif [[ -d "${SRCDIR}/debpython" ]]; then
        _info "debpython already present — skipping rename."
    else
        _die "debpython directory not found after unpack: $unpacked"
    fi

    local fullver="${TERMUX_PKG_VERSION}-${TERMUX_PKG_REVISION}"
    _info "Substituting @TERMUX_PYTHON_VERSION@ → ${_MAJOR_VERSION}"
    _info "Substituting @TERMUX_PKG_FULLVERSION@ → ${fullver}"

    local count=0
    while IFS= read -r -d '' file; do
        # Skip binary files to avoid corrupting them
        if file "$file" 2>/dev/null | grep -qiE 'text|script|python|empty'; then
            if sed --version 2>&1 | grep -q GNU 2>/dev/null; then
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
        fi
    done < <(find "${SRCDIR}/debpython" -type f -print0)

    _ok "debpython: substituted placeholders in ${count} file(s)."

    # Residue check — catch typos in placeholder names
    local residue
    residue="$(grep -rn \
        '@TERMUX_PYTHON_VERSION@\|@TERMUX_PKG_FULLVERSION@' \
        "${SRCDIR}/debpython" 2>/dev/null || true)"
    if [[ -n "$residue" ]]; then
        _warn "Unresolved debpython placeholders remain:"
        printf '%s\n' "$residue" | head -20 >&2
    fi
}

# =============================================================================
# §14  PACK OUTPUT TARBALL  (with integrity verification + companion SHA256 file)
# =============================================================================
_pack_source() {
    if [[ "$_OPT_NO_PACK" == "true" || "$_OPT_DRY_RUN" == "true" ]]; then
        _dry "Would pack: ${OUTPUT_DIR}/${_OUTPUT_TARBALL}"; return 0
    fi

    mkdir -p "$OUTPUT_DIR"
    local out="${OUTPUT_DIR}/${_OUTPUT_TARBALL}"
    local tmp_out="${out}.tmp.$$"

    _info "Packing patched source tree → ${_OUTPUT_TARBALL}"
    _info "  Source dir:  $SRCDIR"
    _info "  Destination: $out"

    # The top-level directory inside the tarball is always "python-src" so
    # build-pkg.sh can extract with --strip-components=1 into any srcdir.
    tar -C "$(dirname "$SRCDIR")" \
        -cJf "$tmp_out" \
        --transform "s|^$(basename "$SRCDIR")|python-src|" \
        "$(basename "$SRCDIR")" \
        || { rm -f "$tmp_out"; _die "tar pack failed."; }

    # Quick integrity check — list the archive to detect truncation
    if ! tar -tJf "$tmp_out" >/dev/null 2>&1; then
        rm -f "$tmp_out"
        _die "Output tarball failed integrity check (truncated or corrupt)."
    fi

    mv "$tmp_out" "$out"
    local size; size="$(du -sh "$out" | cut -f1)"
    local sha;  sha="$(_sha256 "$out")"
    _ok "Packed: $(basename "$out")  (${size})"
    _info "  SHA256: $sha"

    # Companion checksum file consumed by build-pkg.sh and CI
    printf '%s  %s\n' "$sha" "$(basename "$out")" > "${out}.sha256"
    _ok "Wrote: $(basename "$out").sha256"
}

# =============================================================================
# §15  SUMMARY REPORT
# =============================================================================
_print_summary() {
    local elapsed=$(( SECONDS - _START_SECONDS ))
    local mins=$(( elapsed / 60 )) secs=$(( elapsed % 60 ))

    _section "prepare-source.sh — Done"
    printf "  %-24s %s\n" "Python version:"     "${TERMUX_PKG_VERSION}-${TERMUX_PKG_REVISION}"
    printf "  %-24s %s\n" "Android API level:"  "${TERMUX_PKG_API_LEVEL}"
    printf "  %-24s %s\n" "Patches applied:"    "${#_PATCH_FILES[@]}"
    printf "  %-24s %s\n" "autoreconf:"         "$([[ "$_OPT_SKIP_AUTORECONF" == true ]] && echo "skipped" || echo "done")"
    printf "  %-24s %s\n" "Dry-run mode:"       "$_OPT_DRY_RUN"
    printf "  %-24s %s\n" "Elapsed:"            "${mins}m ${secs}s"

    if [[ "$_OPT_DRY_RUN" != "true" && "$_OPT_NO_PACK" != "true" ]]; then
        printf "\n  %-24s %s\n" "Output tarball:" \
            "${OUTPUT_DIR}/${_OUTPUT_TARBALL}"
        printf "  %-24s %s\n" "SHA256 file:" \
            "${OUTPUT_DIR}/${_OUTPUT_TARBALL}.sha256"
        printf "\n  Upload to GitHub release:\n"
        printf "    gh release upload frt '%s'\n\n" \
            "${OUTPUT_DIR}/${_OUTPUT_TARBALL}"
    fi
}

# =============================================================================
# §16  MAIN
# =============================================================================
main() {
    _START_SECONDS=$SECONDS
    _parse_args "$@"
    _setup_env

    _section "Termux Python ${TERMUX_PKG_VERSION} — Prepare Source"
    printf "  %-24s %s\n" "Version:"             "${TERMUX_PKG_VERSION} (rev ${TERMUX_PKG_REVISION})"
    printf "  %-24s %s\n" "API Level:"           "${TERMUX_PKG_API_LEVEL}"
    printf "  %-24s %s\n" "Output:"              "${OUTPUT_DIR}/${_OUTPUT_TARBALL}"
    printf "  %-24s %s\n" "Workdir:"             "${WORKDIR}"
    printf "  %-24s %s\n" "Patch dir:"           "${PATCH_DIR}"
    printf "  %-24s %s\n" "Jobs:"                "${JOBS}"
    printf "  %-24s %s\n" "Dry-run:"             "${_OPT_DRY_RUN}"
    printf "  %-24s %s\n" "Verify patches:"      "${_OPT_VERIFY_PATCHES}"
    printf "  %-24s %s\n" "Skip autoreconf:"     "${_OPT_SKIP_AUTORECONF}"
    printf "  %-24s %s\n" "No-pack:"             "${_OPT_NO_PACK}"
    echo

    _section "Step 1/8 — Tool Check"
    _check_tools

    _section "Step 2/8 — Patch Validation"
    _validate_patches

    _section "Step 3/8 — Clean / Init Workdir"
    if [[ "$_OPT_CLEAN" == "true" && "$_OPT_KEEP_WORKDIR" != "true" ]]; then
        if [[ "$_OPT_DRY_RUN" != "true" ]]; then
            _info "Removing workdir: $WORKDIR"
            rm -rf "$WORKDIR"
            _ok "Workdir removed."
        else
            _dry "Would remove: $WORKDIR"
        fi
    else
        _info "Clean skipped (pass --clean to wipe workdir)."
    fi
    [[ "$_OPT_DRY_RUN" != "true" ]] && mkdir -p "$CACHEDIR" "$LOGDIR" "$SRCDIR"

    _section "Step 4/8 — Download Sources"
    if [[ "$_OPT_DRY_RUN" != "true" ]]; then
        _download "$_PYTHON_URL" \
            "${CACHEDIR}/Python-${TERMUX_PKG_VERSION}.tar.xz" \
            "$_PYTHON_SHA256"
        _download "$_DEBPYTHON_URL" \
            "${CACHEDIR}/python3-defaults-${_DEBPYTHON_COMMIT}.tar.gz" \
            "$_DEBPYTHON_SHA256"
    else
        _dry "Would download: Python-${TERMUX_PKG_VERSION}.tar.xz"
        _dry "Would download: python3-defaults-${_DEBPYTHON_COMMIT}.tar.gz"
    fi

    _section "Step 5/8 — Unpack"
    if [[ "$_OPT_DRY_RUN" != "true" ]]; then
        _info "Unpacking Python-${TERMUX_PKG_VERSION}.tar.xz ..."
        rm -rf "$SRCDIR"; mkdir -p "$SRCDIR"
        tar -xJf "${CACHEDIR}/Python-${TERMUX_PKG_VERSION}.tar.xz" \
            --strip-components=1 -C "$SRCDIR" \
            || _die "Failed to unpack Python tarball."
        _ok "CPython source unpacked  ($(find "$SRCDIR" -type f | wc -l | tr -d ' ') files)."

        _info "Unpacking python3-defaults ..."
        tar -xf "${CACHEDIR}/python3-defaults-${_DEBPYTHON_COMMIT}.tar.gz" \
            -C "$SRCDIR" \
            || _die "Failed to unpack python3-defaults."
        _ok "python3-defaults unpacked."
    else
        _dry "Would unpack Python-${TERMUX_PKG_VERSION}.tar.xz → $SRCDIR"
        _dry "Would unpack python3-defaults → $SRCDIR"
    fi

    _section "Step 6/8 — Apply Patches"
    [[ "$_OPT_DRY_RUN" != "true" ]] && cd "$SRCDIR"
    _apply_0012
    _setup_debpython
    [[ "$_OPT_DRY_RUN" != "true" ]] && _verify_patches_dryrun
    [[ "$_OPT_DRY_RUN" != "true" ]] && cd "$SRCDIR"
    _apply_patches

    _section "Step 7/8 — autoreconf -fi"
    _run_autoreconf

    _section "Step 8/8 — Pack Patched Source"
    _pack_source

    _print_summary
}

_START_SECONDS=$SECONDS
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
