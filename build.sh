#!/usr/bin/env bash
# =============================================================================
# Termux Python 3.13.12 — build.sh
# =============================================================================
# PART 2 OF 2: Download the patched + autoreconf'd source tarball produced by
# prepare-source.sh, cross-compile Python for Android, and produce a .deb
# package for Termux.
#
# Usage:
#   bash build.sh [OPTIONS]
#
# Options:
#   -h, --help         Show this help and exit
#       --clean        Wipe build/src dirs before starting
#       --skip-verify  Skip post-install module verification
#       --no-deb       Build and install only; skip .deb packaging
#       --keep-tests   Do not strip test directories from the install tree
#       --lto          Enable Thin LTO (clang + lld; cross-compile safe)
#       --pgo          Enable PGO (on-device builds only; skipped when cross-compiling)
#
# Environment variables (all auto-detected when not set):
#   PATCHED_SOURCE_URL          URL to python-*-patched-src.tar.xz  [required]
#   TERMUX_PREFIX               Install prefix
#                               (default: $PREFIX, then /data/data/com.termux/files/usr)
#   TERMUX_ARCH                 Target arch: aarch64|arm|i686|x86_64
#                               (default: normalised uname -m)
#   TERMUX_PKG_API_LEVEL        Android API level (default: 35)
#   TERMUX_STANDALONE_TOOLCHAIN NDK toolchain root (default: TERMUX_PREFIX)
#   TERMUX_HOST_PLATFORM        Cross-compile host triple (auto-derived)
#   TERMUX_BUILD_TUPLE          Build-machine triple (auto-derived)
#   TERMUX_ON_DEVICE_BUILD      true|false (auto-detected)
#   TERMUX_PACKAGE_FORMAT       debian|pacman (default: debian)
#   CPU_COUNT                   Parallel make jobs (auto-detected when not set)
#   TERMUX_PKG_MAKE_PROCESSES   Direct job-count override (wins over CPU_COUNT)
#   OUTPUT_DIR                  Where to write the final .deb
#                               (default: directory containing this script)
#   CONF_CACHE                  Extra autoconf cache vars (space-separated)
#   CONF_FLAGS                  Extra configure flags
#   CC, CXX, AR, AS, LD, NM, RANLIB, STRIP, OBJDUMP
#   CFLAGS, CXXFLAGS, LDFLAGS, SYSROOT
#   ANDROID_NDK_HOME
#
# Output:
#   Populated $TERMUX_PREFIX tree, plus a .deb at $OUTPUT_DIR
#
# Examples:
#   # CI runner — all env vars already exported by the workflow:
#   bash build.sh
#
#   # Local Termux on-device build:
#   PATCHED_SOURCE_URL=https://example.com/python-3.13.12-patched-src.tar.xz \
#     bash build.sh
#
#   # Clean rebuild, keep test trees, skip module verification:
#   bash build.sh --clean --keep-tests --skip-verify
#
#   # Build without packaging (useful for iterating on the install):
#   bash build.sh --no-deb
#
#   # Explicit CPU count (normally auto-detected):
#   CPU_COUNT=8 bash build.sh
#
#   # Thin LTO only (cross-compile safe, ~15-25% faster runtime):
#   bash build.sh --lto
#
#   # PGO only (on-device Termux only; silently skipped when cross-compiling):
#   bash build.sh --pgo
#
#   # LTO + PGO (on-device: both active; CI cross-compile: LTO only):
#   bash build.sh --lto --pgo
# =============================================================================
set -euxo pipefail

# =============================================================================
# §0  SCRIPT IDENTITY
# =============================================================================
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly _SCRIPT_DIR

# =============================================================================
# §1  PACKAGE CONSTANTS
# =============================================================================
readonly TERMUX_PKG_HOMEPAGE="https://python.org/"
readonly TERMUX_PKG_DESCRIPTION="Python 3 programming language intended to enable clear programs"
readonly TERMUX_PKG_LICENSE="custom"
readonly TERMUX_PKG_MAINTAINER="Yaksh Bariya <thunder-coding@termux.dev>"
readonly TERMUX_PKG_VERSION="3.13.12"
readonly TERMUX_PKG_REVISION=3
readonly _MAJOR_VERSION="${TERMUX_PKG_VERSION%.*}"

# Name of the patched-source tarball (must match prepare-source.sh)
readonly _PATCHED_TARBALL="python-${TERMUX_PKG_VERSION}-patched-src.tar.xz"

# Required extension modules that must survive post-install
readonly -a _REQUIRED_MODULES=(_bz2 _ctypes _curses _lzma _sqlite3 _ssl _uuid readline zlib)
# _pyrepl is pure Python (Lib/_pyrepl/); verified by directory presence, not import.
readonly _PYREPL_SUBDIR="lib/python${_MAJOR_VERSION}/_pyrepl"

# =============================================================================
# §2  OPTION FLAGS  (only boolean flags remain; everything else is env-driven)
# =============================================================================
_OPT_CLEAN=false
_OPT_SKIP_VERIFY=false
_OPT_NO_DEB=false
_OPT_KEEP_TESTS=false
_OPT_LTO=false
_OPT_PGO=false

# =============================================================================
# §3  LOGGING
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
# §4  ARGUMENT PARSING  (flags only — no value-taking options)
# =============================================================================
_parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --help|-h)
                sed -n '/^# Usage:/,/^# ====/{ /^# ====/d; s/^# \{0,2\}//; p }' "$0"
                exit 0 ;;
            --clean)        _OPT_CLEAN=true ;;
            --skip-verify)  _OPT_SKIP_VERIFY=true ;;
            --no-deb)       _OPT_NO_DEB=true ;;
            --keep-tests)   _OPT_KEEP_TESTS=true ;;
            --lto)          _OPT_LTO=true ;;
            --pgo)          _OPT_PGO=true ;;
            *) _die "Unknown option: '$1'  (try --help)" ;;
        esac
        shift
    done
}

# =============================================================================
# §5  ARCH HELPERS
# =============================================================================

# Normalize raw uname -m / caller-supplied values to Termux canonical form.
# macOS arm64 -> aarch64 ; armv6l/armv7l/armv8l -> arm.
_normalize_arch() {
    case "$1" in
        arm64)       echo "aarch64" ;;
        armv[678]l)  echo "arm"     ;;
        *)           echo "$1"      ;;
    esac
}

_arch_to_triplet() {
    case "$1" in
        aarch64) echo "aarch64-linux-android" ;;
        arm)     echo "arm-linux-androideabi"  ;;
        i686)    echo "i686-linux-android"     ;;
        x86_64)  echo "x86_64-linux-android"   ;;
        *)       _die "Unsupported arch: '$1'. Valid values: aarch64 arm i686 x86_64" ;;
    esac
}

# =============================================================================
# §6  CPU_COUNT  — detect parallel job count once, export for all consumers
# =============================================================================
_detect_cpu_count() {
    # Already set by the caller or a previous run — respect it.
    if [[ -n "${CPU_COUNT:-}" ]]; then
        _info "CPU_COUNT=${CPU_COUNT} (from environment)"
        return
    fi

    local detected=1
    # nproc is available on Linux natively and on macOS when GNU coreutils is
    # installed (which the CI workflow does via brew install coreutils).
    if command -v nproc &>/dev/null; then
        detected="$(nproc)"
    elif command -v sysctl &>/dev/null && sysctl -n hw.ncpu &>/dev/null; then
        detected="$(sysctl -n hw.ncpu)"
    elif [[ -r /proc/cpuinfo ]]; then
        detected="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
    fi

    CPU_COUNT="${detected}"
    export CPU_COUNT
    _info "CPU_COUNT=${CPU_COUNT} (auto-detected)"
}

# =============================================================================
# §7  CROSS-COMPILE DETECTION
# =============================================================================
# Returns 0 (true) when the build host cannot execute the target binaries.
# On a macOS-14 (arm64) CI runner building aarch64-linux-android, the target
# ELF binary cannot be run — module verification must be skipped automatically,
# and PGO (which requires running the instrumented binary) cannot be used.
#
# The test is an affirmative equality check against the canonical value "true"
# rather than a negation, so any value other than exactly "true" — including
# the string "false", an empty string, or an unset variable — is treated as
# cross-compiling.  This avoids the double-negative confusion of testing
# "not true" and makes set -x output unambiguous:
#   cross:      [[ false == true ]]  → exit 1 → _is_cross_compiling returns 0
#   on-device:  [[ true  == true ]]  → exit 0 → _is_cross_compiling returns 1
#
# Note: bash `[[ ]]` exit codes are inverted relative to C: exit 0 = success
# = "the condition is true" for the surrounding if/&&/|| expression.
# The function is named _is_cross_compiling, so callers read naturally:
#   if _is_cross_compiling; then ...   (do something only when cross-compiling)
_is_cross_compiling() {
    [[ "${TERMUX_ON_DEVICE_BUILD}" != "true" ]]
}

# =============================================================================
# §8  ENVIRONMENT DETECTION + DEFAULTS
# =============================================================================
_setup_env() {
    # ── Prefix ────────────────────────────────────────────────────────────────
    # Workflow sets PREFIX=${{ github.workspace }}/prefix; pick that up.
    if [[ -z "${TERMUX_PREFIX:-}" ]]; then
        export TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
    fi

    # ── API level ─────────────────────────────────────────────────────────────
    # Workflow sets TERMUX_PKG_API_LEVEL=35 in env:
    if [[ -z "${TERMUX_PKG_API_LEVEL:-}" ]]; then export TERMUX_PKG_API_LEVEL=35; fi

    # ── Arch (detect then always normalise) ───────────────────────────────────
    # Workflow does not set TERMUX_ARCH; uname -m on macos-14 returns "arm64"
    # which _normalize_arch converts to "aarch64" — the correct Android target.
    if [[ -z "${TERMUX_ARCH:-}" ]]; then TERMUX_ARCH="$(uname -m)"; export TERMUX_ARCH; fi
    TERMUX_ARCH="$(_normalize_arch "$TERMUX_ARCH")"
    export TERMUX_ARCH

    # ── Toolchain + package format ────────────────────────────────────────────
    # Workflow exports TERMUX_STANDALONE_TOOLCHAIN pointing at the NDK toolchain.
    if [[ -z "${TERMUX_STANDALONE_TOOLCHAIN:-}" ]]; then
        export TERMUX_STANDALONE_TOOLCHAIN="${TERMUX_PREFIX}"
    fi
    if [[ -z "${TERMUX_PACKAGE_FORMAT:-}" ]]; then export TERMUX_PACKAGE_FORMAT="debian"; fi

    # ── On-device detection ───────────────────────────────────────────────────
    if [[ -z "${TERMUX_ON_DEVICE_BUILD:-}" ]]; then
        if [[ "$(uname -o 2>/dev/null)" == "Android" ]] || \
           [[ -e "/system/bin/app_process" ]]; then
            export TERMUX_ON_DEVICE_BUILD=true
        else
            export TERMUX_ON_DEVICE_BUILD=false
        fi
    fi

    # ── Host triple (the Android target) ─────────────────────────────────────
    if [[ -z "${TERMUX_HOST_PLATFORM:-}" ]]; then
        TERMUX_HOST_PLATFORM="$(_arch_to_triplet "$TERMUX_ARCH")"
        export TERMUX_HOST_PLATFORM
    fi

    # ── Build triple (the machine running the compiler) ───────────────────────
    # On the macos-14 CI runner: aarch64-apple-darwin.
    # On a Linux x86_64 runner:  x86_64-linux-gnu.
    if [[ -z "${TERMUX_BUILD_TUPLE:-}" ]]; then
        if [[ "$TERMUX_ON_DEVICE_BUILD" == "true" ]]; then
            TERMUX_BUILD_TUPLE="$(_arch_to_triplet "$TERMUX_ARCH")"
        else
            local _host_arch; _host_arch="$(_normalize_arch "$(uname -m)")"
            case "$(uname -s)" in
                Darwin) TERMUX_BUILD_TUPLE="${_host_arch}-apple-darwin" ;;
                *)      TERMUX_BUILD_TUPLE="${_host_arch}-linux-gnu"    ;;
            esac
        fi
        export TERMUX_BUILD_TUPLE
    fi

    # ── Parallel jobs — CPU_COUNT is the single source of truth ──────────────
    _detect_cpu_count
    if [[ -z "${TERMUX_PKG_MAKE_PROCESSES:-}" ]]; then
        TERMUX_PKG_MAKE_PROCESSES="${CPU_COUNT}"
        export TERMUX_PKG_MAKE_PROCESSES
    fi

    # ── Auto-skip module verification when cross-compiling ────────────────────
    # The macOS host runner cannot execute aarch64-linux-android ELF binaries.
    # Suppress the error instead of silently succeeding or crashing.
    if _is_cross_compiling && [[ "$_OPT_SKIP_VERIFY" != "true" ]]; then
        _warn "Cross-compile detected: module verification auto-skipped."
        _warn "  (Host cannot exec target binaries — set --skip-verify to silence this.)"
        _OPT_SKIP_VERIFY=true
    fi

    # ── Working directories ───────────────────────────────────────────────────
    TERMUX_PKG_SRCDIR="${TMPDIR:-/tmp}/python-build/src"
    TERMUX_PKG_BUILDDIR="${TMPDIR:-/tmp}/python-build/build"
    TERMUX_PKG_CACHEDIR="${TMPDIR:-/tmp}/python-build/cache"
    OUTPUT_DIR="${OUTPUT_DIR:-${_SCRIPT_DIR}}"
    export TERMUX_PKG_SRCDIR TERMUX_PKG_BUILDDIR TERMUX_PKG_CACHEDIR OUTPUT_DIR

    # ── Source URL ────────────────────────────────────────────────────────────
    # Strip any leading/trailing whitespace or stray __ sentinel characters that
    # GitHub Actions injects when a ${{ }} expression resolves to empty string
    # (e.g. needs.job.outputs.key undefined -> "__https://...__").
    PATCHED_SOURCE_URL="${PATCHED_SOURCE_URL:-}"
    PATCHED_SOURCE_URL="${PATCHED_SOURCE_URL#__}"    # strip leading __
    PATCHED_SOURCE_URL="${PATCHED_SOURCE_URL%__}"    # strip trailing __
    PATCHED_SOURCE_URL="${PATCHED_SOURCE_URL// /}"   # strip spaces
    export PATCHED_SOURCE_URL

    if [[ -z "$PATCHED_SOURCE_URL" ]]; then
        _die "PATCHED_SOURCE_URL is not set. Check that prepare-source exposes release_tag as a job output."
    fi

    # Reject values that don't look like an HTTP(S) URL — catches the case
    # where ${{ needs.job.outputs.key }} resolved to empty and surrounding
    # literal text collapsed into a non-URL string like
    # '/releases/download//python-3.13.12-patched-src.tar.xz'.
    if [[ "$PATCHED_SOURCE_URL" != http://* && "$PATCHED_SOURCE_URL" != https://* ]]; then
        _die "PATCHED_SOURCE_URL does not look like a URL: '${PATCHED_SOURCE_URL}'. Check release_tag output."
    fi

    _info "Source URL: ${PATCHED_SOURCE_URL}"
    return 0
}

# =============================================================================
# §9  SHA256 + DOWNLOAD
# =============================================================================
_sha256() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        _die "No SHA-256 utility found (install coreutils or shasum)."
    fi
    return 0
}

_download() {
    local url="$1" dest="$2" expected="${3:-}"
    # Use a fixed tmp path (no trap) to avoid the set -u "unbound variable" error
    # that fires when a RETURN trap evaluates $tmp after the local goes out of scope.
    local tmp="${dest}.tmp.$$"

    mkdir -p "$(dirname "$dest")"

    if [[ -f "$dest" ]]; then
        if [[ -z "$expected" ]]; then
            _ok "Cache hit: $(basename "$dest") (no checksum — reusing)"
            return 0
        fi
        local actual; actual="$(_sha256 "$dest")"
        if [[ "$actual" == "$expected" ]]; then
            _ok "Cache hit: $(basename "$dest")"
            return 0
        fi
        _warn "SHA256 mismatch on cached file — re-downloading"
        rm -f "$dest"
    fi

    _info "Downloading: $url"
    if command -v curl &>/dev/null; then
        curl -fL --retry 5 --retry-delay 2 --connect-timeout 30 \
             --progress-bar -o "$tmp" "$url" \
             || { rm -f "$tmp"; _die "curl failed: $url"; }
    elif command -v wget &>/dev/null; then
        wget --tries=5 --timeout=30 -q --show-progress \
             -O "$tmp" "$url" \
             || { rm -f "$tmp"; _die "wget failed: $url"; }
    else
        _die "Neither curl nor wget found."
    fi

    if [[ -n "$expected" ]]; then
        local actual; actual="$(_sha256 "$tmp")"
        if [[ "$actual" != "$expected" ]]; then
            rm -f "$tmp"
            _error "SHA256 mismatch — expected=$expected got=$actual"
            _die "Download integrity check failed."
        fi
    fi

    mv "$tmp" "$dest"
    _ok "Downloaded: $(basename "$dest")"
    return 0
}

# =============================================================================
# §10  TOOL CHECK
# =============================================================================
_check_tools() {
    _info "Checking required build tools ..."
    local -a required=(make tar pkg-config gawk ar zstd)
    local missing=0

    if ! command -v clang &>/dev/null && ! command -v gcc &>/dev/null; then
        required+=(clang)
    fi
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        required+=(curl)
    fi
    for t in "${required[@]}"; do
        if command -v "$t" &>/dev/null; then
            _info "  Found: $t ($(command -v "$t"))"
        else
            _error "Missing: $t"
            (( missing++ )) || true
        fi
    done
    # NOTE: (( expr )) exits 1 when expr==0, which trips set -e.
    # Use [[ ]] for the zero-check so a clean run never causes a false exit.
    if [[ "$missing" -ne 0 ]]; then _die "${missing} required tool(s) missing — install them and retry."; fi
    _ok "All required tools present."
}

# =============================================================================
# §11  PRE-CONFIGURE FLAGS
# =============================================================================
_setup_flags() {
    # Unset host-only pkg-config and include paths exported by the workflow's
    # "Install host dependencies" step. Leaving them in place would cause
    # configure to find host (macOS/x86_64) headers and link against host libs.
    unset PKG_CONFIG_PATH CPPFLAGS_HOST LDFLAGS_HOST

    local _BUILD_PYTHON
    _BUILD_PYTHON="$(command -v "python${_MAJOR_VERSION}" \
                   || command -v python3 \
                   || { _warn "No host Python found; configure may fail."; \
                        echo "python${_MAJOR_VERSION}"; })"
    _info "Host Python: $_BUILD_PYTHON"

    # ── CFLAGS ────────────────────────────────────────────────────────────────
    CFLAGS="${CFLAGS:-}"
    CFLAGS="${CFLAGS/-Oz/-O3}"                       # -Oz breaks Python on Android
    if [[ ! "$CFLAGS" =~ -O[0-9s] ]]; then CFLAGS+=" -O3"; fi
    CFLAGS+=" -fno-semantic-interposition"            # improves call-through-plt perf

    # Ensure --sysroot is in CFLAGS for clang's include resolution.
    # The workflow puts it there, but guard in case of local dev without workflow env.
    if [[ -n "${SYSROOT:-}" ]] && [[ "$CFLAGS" != *--sysroot* ]]; then
        CFLAGS+=" --sysroot=${SYSROOT}"
    fi

    # Ensure -target is in CFLAGS. Required for NDK clang to emit Android ELF.
    if [[ -n "${ANDROID_BUILD_TARGET:-}" ]] && [[ "$CFLAGS" != *-target* ]]; then
        CFLAGS+=" -target ${ANDROID_BUILD_TARGET}"
    fi

    # ── LDFLAGS ───────────────────────────────────────────────────────────────
    LDFLAGS="${LDFLAGS:-}"
    # Remove all occurrences of -Wl,--as-needed — breaks extension module linking.
    # The parameter expansion only removes the first match; use a loop for safety.
    local _ldflags_clean="" _ldf_tok
    for _ldf_tok in $LDFLAGS; do
        [[ "$_ldf_tok" == "-Wl,--as-needed" ]] && continue
        _ldflags_clean="${_ldflags_clean} ${_ldf_tok}"
    done
    LDFLAGS="${_ldflags_clean# }"

    # Ensure --sysroot is in LDFLAGS for the linker (lld) to find Android libc.
    if [[ -n "${SYSROOT:-}" ]] && [[ "$LDFLAGS" != *--sysroot* ]]; then
        LDFLAGS+=" --sysroot=${SYSROOT}"
    fi

    # Use lld — GNU ld cannot link Android ELF correctly on a macOS host.
    if [[ "$LDFLAGS" != *-fuse-ld* ]]; then
        LDFLAGS+=" -fuse-ld=lld"
    fi

    # ── CPPFLAGS + sysroot include / lib ─────────────────────────────────────
    CPPFLAGS="${CPPFLAGS:-}"
    local _sysroot="${TERMUX_STANDALONE_TOOLCHAIN}/sysroot"
    local _sysroot_inc="${_sysroot}/usr/include"
    # NDK 27 layout: usr/lib/<triple>/  (arch-specific subdir)
    # Also add usr/lib/<triple>/<api>/ for versioned stubs.
    local _sysroot_lib_base="${_sysroot}/usr/lib"
    local _sysroot_lib_arch="${_sysroot_lib_base}/${TERMUX_HOST_PLATFORM}"
    local _sysroot_lib_api="${_sysroot_lib_arch}/${TERMUX_PKG_API_LEVEL}"
    if [[ -d "${_sysroot_inc}" ]]; then
        CPPFLAGS+=" -I${_sysroot_inc}"
        # Arch-specific headers (e.g. asm/)
        if [[ -d "${_sysroot_inc}/${TERMUX_HOST_PLATFORM}" ]]; then
            CPPFLAGS+=" -I${_sysroot_inc}/${TERMUX_HOST_PLATFORM}"
        fi
    fi
    if [[ -d "${_sysroot_lib_api}" ]]; then
        LDFLAGS+=" -L${_sysroot_lib_api}"
    fi
    if [[ -d "${_sysroot_lib_arch}" ]]; then
        LDFLAGS+=" -L${_sysroot_lib_arch}"
    fi
    if [[ -d "${_sysroot_lib_base}" ]]; then
        LDFLAGS+=" -L${_sysroot_lib_base}"
    fi

    # ── On-device: explicit API level define ──────────────────────────────────
    if [[ "$TERMUX_ON_DEVICE_BUILD" == "true" ]]; then
        local sdk_ver
        sdk_ver="$(getprop ro.build.version.sdk 2>/dev/null || echo "${TERMUX_PKG_API_LEVEL}")"
        CPPFLAGS+=" -D__ANDROID_API__=${sdk_ver}"
    fi

    # ── autoconf cache vars (unconditional) ───────────────────────────────────
    CONF_CACHE="${CONF_CACHE:-}"
    CONF_CACHE+=" ac_cv_file__dev_ptmx=yes"
    CONF_CACHE+=" ac_cv_file__dev_ptc=no"
    CONF_CACHE+=" ac_cv_func_wcsftime=no"
    CONF_CACHE+=" ac_cv_func_ftime=no"
    CONF_CACHE+=" ac_cv_func_faccessat=no"
    CONF_CACHE+=" ac_cv_func_linkat=no"
    CONF_CACHE+=" ac_cv_buggy_getaddrinfo=no"
    CONF_CACHE+=" ac_cv_little_endian_double=yes"
    CONF_CACHE+=" ac_cv_posix_semaphores_enabled=yes"
    CONF_CACHE+=" ac_cv_func_sem_open=yes"
    CONF_CACHE+=" ac_cv_func_sem_timedwait=yes"
    CONF_CACHE+=" ac_cv_func_sem_getvalue=yes"
    CONF_CACHE+=" ac_cv_func_sem_unlink=yes"
    CONF_CACHE+=" ac_cv_func_shm_open=yes"
    CONF_CACHE+=" ac_cv_func_shm_unlink=yes"
    CONF_CACHE+=" ac_cv_working_tzset=yes"
    CONF_CACHE+=" ac_cv_header_sys_xattr_h=no"
    CONF_CACHE+=" ac_cv_func_getgrent=yes"
    CONF_CACHE+=" ac_cv_func_posix_spawn=yes"
    CONF_CACHE+=" ac_cv_func_posix_spawnp=yes"

    # ── configure feature flags ───────────────────────────────────────────────
    CONF_FLAGS="${CONF_FLAGS:-}"
    CONF_FLAGS+=" --with-build-python=${_BUILD_PYTHON}"
    # --with-system-ffi: tell Python to use the cross-compiled libffi we build in
    #   _build_deps(); without this flag Python uses its bundled copy which ignores
    #   our CPPFLAGS/LDFLAGS and fails to find ffi.h from CROSS_DEPS_PREFIX.
    CONF_FLAGS+=" --with-system-ffi"
    # --with-system-expat omitted: NDK sysroot has no expat headers; use bundled.
    CONF_FLAGS+=" --without-ensurepip"
    # --enable-loadable-sqlite-extensions was removed in Python 3.13.
    # Loadable-extension support is now determined entirely by whether the sqlite3
    # library was compiled with SQLITE_ENABLE_LOAD_EXTENSION=1 (which we do in
    # _build_deps).  Passing the old flag produces "unrecognized option" warnings.
    # Modules that require Tk/Tcl or GNU dbm are not available in the NDK sysroot
    # and cannot be cross-compiled; disable them explicitly so configure does not
    # waste time searching and so the "missing modules" summary is clean.
    CONF_FLAGS+=" --without-tkinter"
    CONF_FLAGS+=" --without-dbmliborder"   # disables dbm, gdbm, ndbm entirely

    # ── API-level-gated cache vars ────────────────────────────────────────────
    if (( TERMUX_PKG_API_LEVEL < 28 )); then
        CONF_CACHE+=" ac_cv_func_fexecve=no ac_cv_func_getlogin_r=no"
    fi
    if (( TERMUX_PKG_API_LEVEL < 29 )); then
        CONF_CACHE+=" ac_cv_func_getloadavg=no"
    fi
    if (( TERMUX_PKG_API_LEVEL < 30 )); then
        CONF_CACHE+=" ac_cv_func_sem_clockwait=no ac_cv_func_memfd_create=no"
    fi
    if (( TERMUX_PKG_API_LEVEL < 31 )); then
        CONF_CACHE+=" ac_cv_func_pidfd_getfd=no ac_cv_func_process_madvise=no"
    fi
    if (( TERMUX_PKG_API_LEVEL < 33 )); then
        CONF_CACHE+=" ac_cv_func_preadv2=no ac_cv_func_pwritev2=no"
    fi
    if (( TERMUX_PKG_API_LEVEL < 34 )); then
        CONF_CACHE+=" ac_cv_func_close_range=no ac_cv_func_copy_file_range=no"
        CONF_CACHE+=" ac_cv_func_posix_spawn_file_actions_addchdir_np=no"
        CONF_CACHE+=" ac_cv_func_posix_spawn_file_actions_addfchdir_np=no"
    fi
    if (( TERMUX_PKG_API_LEVEL < 35 )); then
        CONF_CACHE+=" ac_cv_func_epoll_pwait2=no"
        CONF_CACHE+=" ac_cv_func_tcgetwinsize=no ac_cv_func_tcsetwinsize=no"
    fi
    if (( TERMUX_PKG_API_LEVEL < 36 )); then
        CONF_CACHE+=" ac_cv_func_qsort_r=no"
        CONF_CACHE+=" ac_cv_func_pthread_getaffinity_np=no"
        CONF_CACHE+=" ac_cv_func_pthread_setaffinity_np=no"
    fi

    # ── polyfill libraries ────────────────────────────────────────────────────
    # libandroid-posix-semaphore: named semaphores polyfill for API < 30.
    # libandroid-spawn:           posix_spawn polyfill for API < 28.
    # Both are Termux-installed packages; they do NOT exist in the NDK sysroot
    # and must not be linked on a CI cross-compile where TERMUX_PREFIX is empty.
    # At API >= 30 bionic provides named semaphores natively.
    # At API >= 28 bionic provides posix_spawn natively.
    PYTHON_EXTRA_LDFLAGS=""
    if (( TERMUX_PKG_API_LEVEL < 30 )); then
        if [[ -f "${TERMUX_PREFIX}/lib/libandroid-posix-semaphore.a" ]] || \
           [[ -f "${TERMUX_PREFIX}/lib/libandroid-posix-semaphore.so" ]]; then
            PYTHON_EXTRA_LDFLAGS+=" -landroid-posix-semaphore"
            LDFLAGS+=" -L${TERMUX_PREFIX}/lib"
        else
            _warn "libandroid-posix-semaphore not found in ${TERMUX_PREFIX}/lib — skipping (API ${TERMUX_PKG_API_LEVEL} >= 28, native sem_open available)"
        fi
    fi
    if (( TERMUX_PKG_API_LEVEL < 28 )); then
        if [[ -f "${TERMUX_PREFIX}/lib/libandroid-spawn.a" ]] || \
           [[ -f "${TERMUX_PREFIX}/lib/libandroid-spawn.so" ]]; then
            PYTHON_EXTRA_LDFLAGS+=" -landroid-spawn"
        else
            _warn "libandroid-spawn not found in ${TERMUX_PREFIX}/lib — skipping (API ${TERMUX_PKG_API_LEVEL} >= 28, native posix_spawn available)"
        fi
    fi
    export PYTHON_EXTRA_LDFLAGS
    # libcrypt: not in NDK sysroot; only present inside a Termux install.
    # The crypt module is removed in Python 3.13, so this is only needed for
    # third-party packages that link against libcrypt. Skip on CI.
    if [[ "$TERMUX_ON_DEVICE_BUILD" == "true" ]] || \
       [[ -f "${TERMUX_PREFIX}/lib/libcrypt.a" ]] || \
       [[ -f "${TERMUX_PREFIX}/lib/libcrypt.so" ]]; then
        export LIBCRYPT_LIBS="-lcrypt"
    else
        export LIBCRYPT_LIBS=""
    fi
    export CFLAGS CPPFLAGS LDFLAGS CONF_CACHE CONF_FLAGS
}


# =============================================================================
# §11b  CROSS-COMPILE DEPENDENCIES
# =============================================================================
# Strategy:
#   • bzip2, xz, libffi, ncurses, readline, libuuid — built from source or
#     extracted from Termux .debs (unchanged).
#   • sqlite3, openssl, zstd — downloaded as pre-built BeeWare
#     cpython-android-source-deps tarballs.  These tarballs are produced by
#     the same project that CPython's own Android/android.py uses; they unpack
#     as a flat include/ + lib/ tree directly into CROSS_DEPS_PREFIX with no
#     wrapper subdirectory.  URL pattern:
#       https://github.com/beeware/cpython-android-source-deps/releases/download/
#         <name>-<version>-<revision>/<name>-<version>-<revision>-<host>.tar.gz
#     where <host> is e.g. aarch64-linux-android.
#
# On an on-device build all packages are already installed; we reuse them.
#
# Bump version slugs when upstream ships a new release.
_BZIP2_VERSION="1.0.8"
_XZ_VERSION="5.6.3"
_LIBFFI_VERSION="3.4.7-1"
_LIBFFI_TERMUX_BASE_URL="https://packages.termux.dev/apt/termux-main/pool/main/libf/libffi"

# BeeWare pre-built deps — format: "<name>-<upstream_ver>-<pkg_revision>"
# To update: browse https://github.com/beeware/cpython-android-source-deps/releases
_BEEWARE_DEPS_BASE_URL="https://github.com/beeware/cpython-android-source-deps/releases/download"
_BEEWARE_SQLITE_SLUG="sqlite-3.50.4-0"
_BEEWARE_OPENSSL_SLUG="openssl-3.5.5-0"
_BEEWARE_ZSTD_SLUG="zstd-1.5.7-0"

# readline: extracted from Termux .deb. Requires libncursesw at link time,
# which we already have.
# Package name: readline_VERSION_ARCH.deb  (single package; ships .so + headers)
# To update: browse https://packages.termux.dev/apt/termux-main/pool/main/r/readline/
_READLINE_VERSION="8.3.1-2"
_READLINE_TERMUX_BASE_URL="https://packages.termux.dev/apt/termux-main/pool/main/r/readline"
# libuuid: extracted from Termux util-linux .deb split.
# To update: browse https://packages.termux.dev/apt/termux-main/pool/main/libu/libuuid/
_LIBUUID_VERSION="2.41.3"
_LIBUUID_TERMUX_BASE_URL="https://packages.termux.dev/apt/termux-main/pool/main/libu/libuuid"
# Termux ncurses version to fetch. The arch is substituted at runtime.
# To update: browse https://packages-cf.termux.dev/apt/termux-main/pool/main/n/ncurses/
# and https://packages-cf.termux.dev/apt/termux-main/pool/main/n/ncurses-static/
# Version string uses Termux's epoch+snapshot convention:
#   6.6.20260124+really6.5.20250830
_NCURSES_TERMUX_VERSION="6.6.20260124+really6.5.20250830"
_NCURSES_TERMUX_BASE_URL="https://packages.termux.dev/apt/termux-main/pool/main/n"

# URL-encode '+' as '%2B' for the ncurses version used in download URLs.
_ncurses_version_url() { printf '%s' "${_NCURSES_TERMUX_VERSION//+/%2B}"; }

# _strip_sentinels <varname>
# GitHub Actions injects __ prefix/suffix when a workflow env: block sets a
# variable to a value that expands from an empty expression, or when env vars
# bleed across job steps.  Strip them in-place using only bash 3.2-compatible
# syntax (no namerefs, no declare -n).
_strip_sentinels() {
    local _var="$1"
    local _val="${!_var}"
    _val="${_val#__}"   # strip leading __
    _val="${_val%__}"   # strip trailing __
    _val="${_val// /}"  # strip stray spaces
    eval "${_var}=\${_val}"
}

# _sanitise_dep_urls — strip __ sentinels from every URL global before use.
# Called once at the start of _build_deps.
_sanitise_dep_urls() {
    local _v
    for _v in \
        _BEEWARE_DEPS_BASE_URL    \
        _LIBFFI_TERMUX_BASE_URL   \
        _READLINE_TERMUX_BASE_URL \
        _LIBUUID_TERMUX_BASE_URL  \
        _NCURSES_TERMUX_BASE_URL; do
        _strip_sentinels "$_v"
    done
}

# _dep_sha256 <tarball-filename>
# Returns the expected SHA-256 for a source tarball, or empty string to skip
# verification.  bzip2 and xz are pure source tarballs — the bytes are
# identical on every build host regardless of target arch, so one hash each
# is sufficient.  Update values here when bumping _BZIP2_VERSION / _XZ_VERSION.
_dep_sha256() {
    case "$1" in
        "bzip2-1.0.8.tar.gz")
            # https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz
            printf '%s' "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269" ;;
        "xz-${_XZ_VERSION}.tar.xz")
            # https://github.com/tukaani-project/xz/releases/download/v5.6.3/xz-5.6.3.tar.xz
            # Hash captured from CI (macOS aarch64 runner); source tarball is
            # arch-independent so this hash is valid on all build hosts.
            printf '%s' "db0590629b6f0fa36e74aea5f9731dc6f8df068ce7b7bafa45301832a5eebc3a" ;;
        *)
            printf '%s' "" ;;   # unknown — skip checksum
    esac
}

_build_deps() {
    if [[ "$TERMUX_ON_DEVICE_BUILD" == "true" ]]; then
        _info "On-device build — using TERMUX_PREFIX libraries for dependencies."
        CROSS_DEPS_PREFIX="${TERMUX_PREFIX}"
        export CROSS_DEPS_PREFIX
        return 0
    fi

    # Strip any __ sentinel wrapping that GitHub Actions may have injected
    # into URL globals before we make any network requests.
    _sanitise_dep_urls

    CROSS_DEPS_PREFIX="${TMPDIR:-/tmp}/python-build/deps"
    export CROSS_DEPS_PREFIX
    local log_dir="${CROSS_DEPS_PREFIX}/build-logs"
    local deps_build="${TMPDIR:-/tmp}/python-build/deps-build"
    mkdir -p "${CROSS_DEPS_PREFIX}" "${log_dir}" "${deps_build}" "${TERMUX_PKG_CACHEDIR}"

    # Capture the cross-compile tools and flags that were set by _setup_flags.
    local _cc="${CC:-clang}"
    local _cxx="${CXX:-clang++}"
    local _ar="${AR:-llvm-ar}"
    local _ranlib="${RANLIB:-llvm-ranlib}"
    local _cflags="${CFLAGS:-}"
    local _ldflags="${LDFLAGS:-}"

    # ── helper: download + extract source tarball ─────────────────────────────
    _dl_extract() {
        local url="$1" tarball="$2" dir="$3"
        local sha; sha="$(_dep_sha256 "$tarball")"
        _download "$url" "${TERMUX_PKG_CACHEDIR}/${tarball}" "$sha"
        if [[ -d "$dir" ]]; then
            _info "  Already extracted: $(basename "$dir")"
            return 0
        fi
        mkdir -p "$(dirname "$dir")"
        case "$tarball" in
            *.tar.xz)       tar -xJf "${TERMUX_PKG_CACHEDIR}/${tarball}" -C "$(dirname "$dir")" ;;
            *.tar.gz|*.tgz) tar -xzf "${TERMUX_PKG_CACHEDIR}/${tarball}" -C "$(dirname "$dir")" ;;
            *.tar.bz2)      tar -xjf "${TERMUX_PKG_CACHEDIR}/${tarball}" -C "$(dirname "$dir")" ;;
            *)              _die "_dl_extract: unknown archive type: $tarball" ;;
        esac
        return 0
    }

    # ── bzip2 ─────────────────────────────────────────────────────────────────
    local bz2_src="${deps_build}/bzip2-${_BZIP2_VERSION}"
    if [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libbz2.a" ]]; then
        _info "Building bzip2 ${_BZIP2_VERSION} ..."
        _dl_extract \
            "https://sourceware.org/pub/bzip2/bzip2-${_BZIP2_VERSION}.tar.gz" \
            "bzip2-${_BZIP2_VERSION}.tar.gz" \
            "$bz2_src"
        make -C "$bz2_src" -j"${TERMUX_PKG_MAKE_PROCESSES}" \
            CC="${_cc}" AR="${_ar}" RANLIB="${_ranlib}" \
            CFLAGS="${_cflags} -fPIC" \
            libbz2.a \
            > "${log_dir}/bzip2.log" 2>&1 \
            || { cat "${log_dir}/bzip2.log"; _die "bzip2 build failed."; }
        install -d "${CROSS_DEPS_PREFIX}/lib" "${CROSS_DEPS_PREFIX}/include"
        install -m 644 "${bz2_src}/libbz2.a" "${CROSS_DEPS_PREFIX}/lib/"
        install -m 644 "${bz2_src}/bzlib.h"  "${CROSS_DEPS_PREFIX}/include/"
        _ok "bzip2 built."
    else
        _info "bzip2 already built — skipping."
    fi

    # ── xz / liblzma ──────────────────────────────────────────────────────────
    local xz_src="${deps_build}/xz-${_XZ_VERSION}"
    if [[ ! -f "${CROSS_DEPS_PREFIX}/lib/liblzma.a" ]]; then
        _info "Building xz/liblzma ${_XZ_VERSION} ..."
        _dl_extract \
            "https://github.com/tukaani-project/xz/releases/download/v${_XZ_VERSION}/xz-${_XZ_VERSION}.tar.xz" \
            "xz-${_XZ_VERSION}.tar.xz" \
            "$xz_src"
        (
            mkdir -p "${xz_src}/cross-build"
            cd "${xz_src}/cross-build"
            "${xz_src}/configure" \
                --prefix="${CROSS_DEPS_PREFIX}" \
                --host="${TERMUX_HOST_PLATFORM}" \
                --build="${TERMUX_BUILD_TUPLE}" \
                --disable-shared --enable-static \
                --disable-xz --disable-xzdec --disable-lzmadec \
                --disable-lzmainfo --disable-scripts --disable-doc \
                CC="${_cc}" CFLAGS="${_cflags} -fPIC" LDFLAGS="${_ldflags}" \
                > "${log_dir}/xz-configure.log" 2>&1 \
                || { cat "${log_dir}/xz-configure.log"; _die "xz configure failed."; }
            make -j"${TERMUX_PKG_MAKE_PROCESSES}" \
                >> "${log_dir}/xz-configure.log" 2>&1 \
                || { cat "${log_dir}/xz-configure.log"; _die "xz build failed."; }
            make install \
                >> "${log_dir}/xz-configure.log" 2>&1 \
                || _die "xz install failed."
        )
        _ok "xz/liblzma built."
    else
        _info "xz/liblzma already built — skipping."
    fi

    # ── helper: download + unpack a BeeWare pre-built dep tarball ────────────
    # BeeWare tarballs unpack as a flat include/ + lib/ tree with no top-level
    # wrapper directory — exactly how CPython's own Android/android.py uses them
    # (shutil.unpack_archive into the prefix dir directly).
    # sentinel_file: a file whose presence means the tarball was already unpacked.
    _beeware_extract() {
        local slug="$1" sentinel="$2"
        if [[ -f "${CROSS_DEPS_PREFIX}/${sentinel}" ]]; then
            _info "  BeeWare ${slug}: already present — skipping."
            return 0
        fi
        local filename="${slug}-${TERMUX_HOST_PLATFORM}.tar.gz"
        local url="${_BEEWARE_DEPS_BASE_URL}/${slug}/${filename}"
        local cached="${TERMUX_PKG_CACHEDIR}/${filename}"
        _download "$url" "$cached"
        _info "  Unpacking ${filename} into ${CROSS_DEPS_PREFIX} ..."
        # Extract in a subshell so the cd doesn't affect the parent.
        (
            cd "${CROSS_DEPS_PREFIX}"
            tar -xzf "$cached"
        ) || _die "Failed to unpack ${filename}"
        _ok "  BeeWare ${slug}: unpacked."
    }

    # ── sqlite3 — BeeWare pre-built ───────────────────────────────────────────
    # Pre-built with SQLITE_ENABLE_LOAD_EXTENSION=1 and all standard features.
    # Unpacks as include/sqlite3.h + lib/libsqlite3.{a,so} + lib/pkgconfig/sqlite3.pc
    _beeware_extract "${_BEEWARE_SQLITE_SLUG}" "include/sqlite3.h"

    # ── openssl — BeeWare pre-built ───────────────────────────────────────────
    # Unpacks as include/openssl/*.h + lib/libssl.a + lib/libcrypto.a + pkgconfig
    _beeware_extract "${_BEEWARE_OPENSSL_SLUG}" "include/openssl/ssl.h"

    # ── zstd — BeeWare pre-built ──────────────────────────────────────────────
    # Provides libzstd for Python's _zstd module (new in 3.14; harmless in 3.13)
    # and is also used by some Termux packages at runtime.
    # Unpacks as include/zstd.h + lib/libzstd.{a,so} + lib/pkgconfig/libzstd.pc
    _beeware_extract "${_BEEWARE_ZSTD_SLUG}" "include/zstd.h"

    # ── libffi — extracted from Termux .deb ─────────────────────────────────
    # Required for _ctypes (and therefore ctypes / _pyrepl).
    # Same approach as ncurses: extract prebuilt Termux aarch64 .deb rather
    # than building from source. The .so is present on every Termux device.
    # Pool path pattern: pool/main/libf/libffi/libffi_<ver>_<arch>.deb
    if [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libffi.so"  ]] || \
       [[ ! -f "${CROSS_DEPS_PREFIX}/include/ffi.h"  ]]; then
        _info "Extracting libffi ${_LIBFFI_VERSION} from Termux .deb ..."
        local _ffi_arch="${TERMUX_HOST_PLATFORM%%-*}"  # aarch64, arm, i686, x86_64
        # Termux uses "arm" for 32-bit ARM in the package filename
        local ffi_deb="${TERMUX_PKG_CACHEDIR}/libffi.deb"
        _download \
            "${_LIBFFI_TERMUX_BASE_URL}/libffi_${_LIBFFI_VERSION}_${_ffi_arch}.deb" \
            "$ffi_deb"

        local ffi_extract="${deps_build}/libffi-deb"
        rm -rf "$ffi_extract"; mkdir -p "$ffi_extract"
        local ffi_tmp="${ffi_extract}/tmp"
        mkdir -p "$ffi_tmp"
        (
            cd "$ffi_tmp"
            ar x "$ffi_deb"
            local data_tar
            data_tar="$(ls data.tar.* 2>/dev/null | head -1)"
            [[ -n "$data_tar" ]] || _die "No data.tar.* in libffi.deb"
            case "$data_tar" in
                *.xz)  tar -xJf "$data_tar" -C "$ffi_extract" ;;
                *.gz)  tar -xzf "$data_tar" -C "$ffi_extract" ;;
                *.zst) zstd -d  "$data_tar" --stdout | tar -x -C "$ffi_extract" ;;
                *)     _die "Unknown format: $data_tar" ;;
            esac
        )

        local ffi_usr="${ffi_extract}/data/data/com.termux/files/usr"
        [[ -d "$ffi_usr" ]] || _die "libffi .deb extraction failed — tree not at ${ffi_usr}"

        install -d "${CROSS_DEPS_PREFIX}/include" "${CROSS_DEPS_PREFIX}/lib"

        # Headers: ffi.h + ffitarget.h
        for _hdr in ffi.h ffitarget.h; do
            [[ -f "${ffi_usr}/include/${_hdr}" ]] && \
                cp -a "${ffi_usr}/include/${_hdr}" "${CROSS_DEPS_PREFIX}/include/"
        done
        # Shared libraries
        local _ffi_found=0
        for f in "${ffi_usr}/lib"/libffi*.so*; do
            [[ -e "$f" ]] && cp -a "$f" "${CROSS_DEPS_PREFIX}/lib/" && (( _ffi_found++ )) || true
        done
        [[ "$_ffi_found" -gt 0 ]] || _die "No libffi .so files found in extracted .deb"
        # Stub .a for configure probes (link uses .so at runtime on device)
        local _dep_ar="${AR:-llvm-ar}"
        [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libffi.a" ]] && \
            "${_dep_ar}" rcs "${CROSS_DEPS_PREFIX}/lib/libffi.a" 2>/dev/null || true
        _ok "libffi extracted (${_ffi_found} .so files)."
    else
        _info "libffi already present — skipping."
    fi

    # ── ncurses — extracted from Termux .deb (shared lib approach) ─────────
    # ncurses cross-compilation from source is not viable in a single-phase build:
    # its makefiles require build-host helper binaries in ../lib/ before they can
    # compile the target library, which never works cleanly in cross setups.
    # We extract libncursesw.so (+ symlinks) and headers from the official Termux
    # aarch64 .deb and link Python's _curses extension against the shared lib.
    # The .so is present on every Termux installation via the ncurses package.
    if [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libncursesw.so"         ]] || \
       [[ ! -f "${CROSS_DEPS_PREFIX}/include/curses.h"           ]] || \
       [[ ! -f "${CROSS_DEPS_PREFIX}/include/ncursesw/curses.h"  ]]; then
        _info "Extracting ncurses from Termux .deb ..."
        local _nc_arch="${TERMUX_HOST_PLATFORM%%-*}"  # aarch64 from aarch64-linux-android
        local _nc_ver_url; _nc_ver_url="$(_ncurses_version_url)"
        local nc_lib_deb="${TERMUX_PKG_CACHEDIR}/ncurses.deb"
        local nc_static_deb="${TERMUX_PKG_CACHEDIR}/ncurses-static.deb"
        _download \
            "${_NCURSES_TERMUX_BASE_URL}/ncurses/ncurses_${_nc_ver_url}_${_nc_arch}.deb" \
            "$nc_lib_deb"
        _download \
            "${_NCURSES_TERMUX_BASE_URL}/ncurses-static/ncurses-static_${_nc_ver_url}_${_nc_arch}.deb" \
            "$nc_static_deb"

        local nc_extract="${deps_build}/ncurses-deb"
        rm -rf "$nc_extract"
        mkdir -p "$nc_extract"

        # Extract both .deb archives (standard ar + data.tar.*)
        for deb in "$nc_lib_deb" "$nc_static_deb"; do
            local deb_tmp="${nc_extract}/tmp_$(basename "$deb")"
            mkdir -p "$deb_tmp"
            (
                cd "$deb_tmp"
                ar x "$deb"
                local data_tar
                data_tar="$(ls data.tar.* 2>/dev/null | head -1)"
                if [[ -z "$data_tar" ]]; then
                    _die "No data.tar.* found in $(basename "$deb")"
                fi
                case "$data_tar" in
                    *.xz)  tar -xJf "$data_tar" -C "$nc_extract" ;;
                    *.gz)  tar -xzf "$data_tar" -C "$nc_extract" ;;
                    *.zst) zstd -d  "$data_tar" --stdout | tar -x -C "$nc_extract" ;;
                    *)     _die "Unknown data archive format: $data_tar" ;;
                esac
            )
        done

        # Termux installs under /data/data/com.termux/files/usr
        local termux_usr="${nc_extract}/data/data/com.termux/files/usr"
        if [[ ! -d "$termux_usr" ]]; then
            ls -la "$nc_extract" || true
            _die "ncurses .deb extraction failed — expected tree at ${termux_usr}"
        fi

        install -d "${CROSS_DEPS_PREFIX}/include" "${CROSS_DEPS_PREFIX}/lib"

        # ── Headers ──────────────────────────────────────────────────────────
        if [[ -d "${termux_usr}/include/ncursesw" ]]; then
            cp -a "${termux_usr}/include/ncursesw" "${CROSS_DEPS_PREFIX}/include/"
            _info "  Installed ncursesw/ headers."
        else
            _warn "  ncursesw/ headers not found in .deb — _curses may not build."
        fi

        for _hdr in curses.h ncurses.h unctrl.h term.h termcap.h; do
            local _src="${termux_usr}/include/${_hdr}"
            local _dst="${CROSS_DEPS_PREFIX}/include/${_hdr}"
            if [[ -f "$_src" ]]; then
                cp -a "$_src" "$_dst"
            elif [[ ! -f "$_dst" ]]; then
                printf '#ifndef _NCURSES_SHIM_%s\n#define _NCURSES_SHIM_%s\n#include <ncursesw/%s>\n#endif\n' \
                    "${_hdr//./_}" "${_hdr//./_}" "$_hdr" > "$_dst"
            fi
        done
        _info "  Installed flat curses.h shim headers."

        if [[ ! -d "${CROSS_DEPS_PREFIX}/include/ncurses" ]]; then
            ln -sf ncursesw "${CROSS_DEPS_PREFIX}/include/ncurses" 2>/dev/null || true
        fi

        local _nc_found=0
        for f in "${termux_usr}/lib"/libncurses*.so* \
                 "${termux_usr}/lib"/libpanel*.so*   \
                 "${termux_usr}/lib"/libform*.so*    \
                 "${termux_usr}/lib"/libmenu*.so*; do
            if [[ -e "$f" ]]; then
                cp -a "$f" "${CROSS_DEPS_PREFIX}/lib/"
                (( _nc_found++ )) || true
            fi
        done
        if [[ "$_nc_found" -eq 0 ]]; then
            _die "No ncurses .so files found in extracted .deb — check URLs."
        fi
        _info "  Installed ${_nc_found} ncurses library files."

        local _nc_so
        _nc_so="$(ls "${CROSS_DEPS_PREFIX}/lib/libncursesw.so."* 2>/dev/null | head -1 || true)"
        if [[ -z "$_nc_so" ]]; then
            _nc_so="$(ls "${CROSS_DEPS_PREFIX}/lib/libncursesw.so" 2>/dev/null || true)"
        fi
        if [[ -n "$_nc_so" ]] && [[ ! -e "${CROSS_DEPS_PREFIX}/lib/libncurses.so" ]]; then
            ln -sf "$(basename "$_nc_so")"                    "${CROSS_DEPS_PREFIX}/lib/libncurses.so" 2>/dev/null || true
        fi

        local _dep_ar="${AR:-llvm-ar}"
        for stub in libncursesw.a libncurses.a; do
            if [[ ! -f "${CROSS_DEPS_PREFIX}/lib/${stub}" ]]; then
                "${_dep_ar}" rcs "${CROSS_DEPS_PREFIX}/lib/${stub}" 2>/dev/null || true
            fi
        done

        _ok "ncurses extracted from Termux .deb."
    else
        _info "ncurses already present — skipping."
    fi

    # ── readline — extracted from Termux .deb ────────────────────────────────
    # Python's readline module links against libreadline, which in turn needs
    # libncursesw.  Both are already in CROSS_DEPS_PREFIX.
    # Package: readline_VERSION_ARCH.deb  (single deb; ships .so + headers)
    # URL pattern: BASE/readline_VERSION_ARCH.deb
    if [[ ! -f "${CROSS_DEPS_PREFIX}/include/readline/readline.h" ]] || \
       [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libreadline.so"          ]]; then
        _info "Extracting readline ${_READLINE_VERSION} from Termux .deb ..."
        # Arch suffix in Termux package filenames is the short form (aarch64,
        # arm, i686, x86_64) — strip everything after the first '-' in the
        # host triple to get it.
        local _rl_arch="${TERMUX_HOST_PLATFORM%%-*}"
        local rl_deb="${TERMUX_PKG_CACHEDIR}/readline.deb"
        _download \
            "${_READLINE_TERMUX_BASE_URL}/readline_${_READLINE_VERSION}_${_rl_arch}.deb" \
            "$rl_deb"

        local rl_extract="${deps_build}/readline-deb"
        rm -rf "$rl_extract"; mkdir -p "$rl_extract"
        local rl_tmp="${rl_extract}/tmp"
        mkdir -p "$rl_tmp"
        (
            cd "$rl_tmp"
            ar x "$rl_deb"
            local data_tar
            data_tar="$(ls data.tar.* 2>/dev/null | head -1)"
            [[ -n "$data_tar" ]] || _die "No data.tar.* in readline.deb"
            case "$data_tar" in
                *.xz)  tar -xJf "$data_tar" -C "$rl_extract" ;;
                *.gz)  tar -xzf "$data_tar" -C "$rl_extract" ;;
                *.zst) zstd -d  "$data_tar" --stdout | tar -x -C "$rl_extract" ;;
                *)     _die "Unknown format: $data_tar" ;;
            esac
        )

        local rl_usr="${rl_extract}/data/data/com.termux/files/usr"
        [[ -d "$rl_usr" ]] || _die "readline .deb extraction failed — tree not at ${rl_usr}"

        install -d "${CROSS_DEPS_PREFIX}/include/readline" "${CROSS_DEPS_PREFIX}/lib"

        # Headers
        for _hdr in readline.h history.h keymaps.h chardefs.h tilde.h; do
            [[ -f "${rl_usr}/include/readline/${_hdr}" ]] && \
                cp -a "${rl_usr}/include/readline/${_hdr}" \
                      "${CROSS_DEPS_PREFIX}/include/readline/" || true
        done

        # Shared libraries
        local _rl_found=0
        for f in "${rl_usr}/lib"/libreadline*.so*; do
            [[ -e "$f" ]] && cp -a "$f" "${CROSS_DEPS_PREFIX}/lib/" && (( _rl_found++ )) || true
        done
        [[ "$_rl_found" -gt 0 ]] || _die "No libreadline .so files found in extracted .deb"

        # Stub .a for configure probes
        local _dep_ar="${AR:-llvm-ar}"
        [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libreadline.a" ]] && \
            "${_dep_ar}" rcs "${CROSS_DEPS_PREFIX}/lib/libreadline.a" 2>/dev/null || true

        _ok "readline extracted (${_rl_found} .so files)."
    else
        _info "readline already present — skipping."
    fi

    # ── libuuid — extracted from Termux .deb ─────────────────────────────────
    # Python's _uuid module needs uuid/uuid.h and libuuid.
    if [[ ! -f "${CROSS_DEPS_PREFIX}/include/uuid/uuid.h" ]] || \
       [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libuuid.so"       ]]; then
        _info "Extracting libuuid ${_LIBUUID_VERSION} from Termux .deb ..."
        local _uuid_arch="${TERMUX_HOST_PLATFORM%%-*}"
        local uuid_deb="${TERMUX_PKG_CACHEDIR}/libuuid.deb"
        _download \
            "${_LIBUUID_TERMUX_BASE_URL}/libuuid_${_LIBUUID_VERSION}_${_uuid_arch}.deb" \
            "$uuid_deb"

        local uuid_extract="${deps_build}/libuuid-deb"
        rm -rf "$uuid_extract"; mkdir -p "$uuid_extract"
        local uuid_tmp="${uuid_extract}/tmp"
        mkdir -p "$uuid_tmp"
        (
            cd "$uuid_tmp"
            ar x "$uuid_deb"
            local data_tar
            data_tar="$(ls data.tar.* 2>/dev/null | head -1)"
            [[ -n "$data_tar" ]] || _die "No data.tar.* in libuuid.deb"
            case "$data_tar" in
                *.xz)  tar -xJf "$data_tar" -C "$uuid_extract" ;;
                *.gz)  tar -xzf "$data_tar" -C "$uuid_extract" ;;
                *.zst) zstd -d  "$data_tar" --stdout | tar -x -C "$uuid_extract" ;;
                *)     _die "Unknown format: $data_tar" ;;
            esac
        )

        local uuid_usr="${uuid_extract}/data/data/com.termux/files/usr"
        [[ -d "$uuid_usr" ]] || _die "libuuid .deb extraction failed — tree not at ${uuid_usr}"

        install -d "${CROSS_DEPS_PREFIX}/include/uuid" "${CROSS_DEPS_PREFIX}/lib"

        [[ -f "${uuid_usr}/include/uuid/uuid.h" ]] && \
            cp -a "${uuid_usr}/include/uuid/uuid.h" "${CROSS_DEPS_PREFIX}/include/uuid/"

        local _uuid_found=0
        for f in "${uuid_usr}/lib"/libuuid*.so*; do
            [[ -e "$f" ]] && cp -a "$f" "${CROSS_DEPS_PREFIX}/lib/" && (( _uuid_found++ )) || true
        done
        [[ "$_uuid_found" -gt 0 ]] || _die "No libuuid .so files found in extracted .deb"

        local _dep_ar="${AR:-llvm-ar}"
        [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libuuid.a" ]] && \
            "${_dep_ar}" rcs "${CROSS_DEPS_PREFIX}/lib/libuuid.a" 2>/dev/null || true

        _ok "libuuid extracted (${_uuid_found} .so files)."
    else
        _info "libuuid already present — skipping."
    fi

    # ── Point Python build at the cross-built deps ────────────────────────────
    CPPFLAGS+=" -I${CROSS_DEPS_PREFIX}/include"
    LDFLAGS+=" -L${CROSS_DEPS_PREFIX}/lib"
    export PKG_CONFIG_PATH="${CROSS_DEPS_PREFIX}/lib/pkgconfig"
    export PKG_CONFIG_LIBDIR="${CROSS_DEPS_PREFIX}/lib/pkgconfig"
    export CPPFLAGS LDFLAGS

    # CURSES_CFLAGS / CURSES_LIBS / PANEL_LIBS must be exported as environment
    # variables, NOT passed as positional KEY=val arguments to configure.
    # autoconf only treats positional KEY=val as cache-variable overrides for
    # names matching ac_cv_*; any other KEY=val is silently ignored.
    # Exporting them causes configure's AC_CHECK_LIB / AC_CHECK_HEADER probes
    # to pick up the cross-compiled ncurses headers and shared library.
    export CURSES_CFLAGS="-I${CROSS_DEPS_PREFIX}/include/ncursesw"
    export CURSES_LIBS="-lncursesw"
    export PANEL_LIBS="-lpanelw"

    # readline: tell Python configure exactly where our cross-built readline is.
    export READLINE_CFLAGS="-I${CROSS_DEPS_PREFIX}/include"
    export READLINE_LIBS="-lreadline -lncursesw"

    # _uuid: uuid.h is at CROSS_DEPS_PREFIX/include/uuid/uuid.h;
    # CPPFLAGS already includes CROSS_DEPS_PREFIX/include so uuid/uuid.h resolves.
    export LIBUUID_CFLAGS="-I${CROSS_DEPS_PREFIX}/include"
    export LIBUUID_LIBS="-luuid"

    _ok "All cross-compiled dependencies ready at ${CROSS_DEPS_PREFIX}."
    return 0
}

# =============================================================================
# §11c  LTO / PGO FLAGS
# =============================================================================
_setup_lto_pgo() {
    # ── LTO ──────────────────────────────────────────────────────────────────
    if [[ "$_OPT_LTO" == "true" ]]; then
        _info "LTO: thin LTO requested."
        CONF_FLAGS+=" --with-lto=thin"
        if [[ "$LDFLAGS" != *-fuse-ld=lld* ]]; then
            LDFLAGS+=" -fuse-ld=lld"
            _info "LTO: added -fuse-ld=lld to LDFLAGS."
        fi
        # NDK r23+ ships lld with ThinLTO support compiled in.  No external
        # libLTO.* plugin is loaded or needed — lld handles the cross-TU
        # optimisation pass internally.  Do NOT search for libLTO.* and do NOT
        # add its directory to LDFLAGS; the file is absent in NDK r23+ and any
        # -L pointing at a nonexistent path wastes linker search time.
        export LDFLAGS CONF_FLAGS
        _ok "LTO: --with-lto=thin enabled."
    else
        _info "LTO: not requested (pass --lto to enable)."
    fi

    # ── PGO ──────────────────────────────────────────────────────────────────
    if [[ "$_OPT_PGO" == "true" ]]; then
        if _is_cross_compiling; then
            # Expected on every CI cross-compile run — not an error, just a
            # capability gap.  The instrumented Python binary targets Android
            # ELF and cannot execute on the macOS / Linux build host.
            # CPython's configure + Makefile have no remote-execution PGO mode,
            # so we skip silently.  Re-run inside Termux on the device, or set
            # TERMUX_ON_DEVICE_BUILD=true for a native build.
            _info "PGO: cross-compile detected (TERMUX_ON_DEVICE_BUILD=${TERMUX_ON_DEVICE_BUILD}) — PGO skipped."
            _info "     Pass --pgo on an on-device Termux build to enable profile-guided optimisation."
        else
            CONF_FLAGS+=" --enable-optimizations"
            export CONF_FLAGS
            _ok "PGO: --enable-optimizations enabled."
            _warn "PGO: build time will be roughly 3× longer than a standard build."
        fi
    else
        _info "PGO: not requested (pass --pgo to enable; on-device builds only)."
    fi
}

# =============================================================================
# §12  CONFIGURE
# =============================================================================
_do_configure() {
    mkdir -p "$TERMUX_PKG_BUILDDIR"
    cd "$TERMUX_PKG_BUILDDIR"

    local configure_log="${TERMUX_PKG_BUILDDIR}/configure.log"
    _info "Running ./configure (log: ${configure_log}) ..."
    _info "  CC:      ${CC:-<unset>}"
    _info "  CXX:     ${CXX:-<unset>}"
    _info "  CFLAGS:  ${CFLAGS:-<unset>}"
    _info "  LDFLAGS: ${LDFLAGS:-<unset>}"

    # Resolve --with-system-ffi: the flag name changed in Python 3.13.
    # In 3.13+ the option is simply gone from configure — libffi is always
    # sought via pkg-config / CPPFLAGS / LDFLAGS when present.  Passing the
    # old flag produces "unrecognized option" warnings that pollute the log
    # and, on strict setups, cause confusion.  We probe configure --help and
    # only pass the flag when it is actually accepted.
    local _ffi_flag=""
    if "${TERMUX_PKG_SRCDIR}/configure" --help 2>/dev/null | grep -q -- '--with-system-ffi'; then
        _ffi_flag="--with-system-ffi"
        _info "configure: --with-system-ffi accepted — passing it."
    else
        _info "configure: --with-system-ffi not recognized (Python 3.13+) — omitting."
        _info "  libffi will be located via PKG_CONFIG_PATH / CPPFLAGS / LDFLAGS."
        # Strip any occurrence already in CONF_FLAGS (added by _setup_flags).
        CONF_FLAGS="${CONF_FLAGS/--with-system-ffi/}"
        export CONF_FLAGS
    fi

    # shellcheck disable=SC2086
    "${TERMUX_PKG_SRCDIR}/configure" \
        --prefix="${TERMUX_PREFIX}"              \
        --host="${TERMUX_HOST_PLATFORM}"         \
        --build="${TERMUX_BUILD_TUPLE}"          \
        --enable-shared                          \
        ${_ffi_flag:+"$_ffi_flag"}               \
        ${CONF_CACHE}                            \
        ${CONF_FLAGS}                            \
        CC="${CC:-clang}"                        \
        CXX="${CXX:-clang++}"                    \
        AR="${AR:-llvm-ar}"                      \
        RANLIB="${RANLIB:-llvm-ranlib}"          \
        STRIP="${STRIP:-llvm-strip}"             \
        CFLAGS="${CFLAGS}"                       \
        CPPFLAGS="${CPPFLAGS}"                   \
        LDFLAGS="${LDFLAGS}"                     \
        LIBCRYPT_LIBS="${LIBCRYPT_LIBS:-}"       \
        CURSES_CFLAGS="${CURSES_CFLAGS:-}"       \
        CURSES_LIBS="${CURSES_LIBS:-}"           \
        PANEL_LIBS="${PANEL_LIBS:-}"             \
        READLINE_CFLAGS="${READLINE_CFLAGS:-}"   \
        READLINE_LIBS="${READLINE_LIBS:-}"       \
        LIBUUID_CFLAGS="${LIBUUID_CFLAGS:-}"     \
        LIBUUID_LIBS="${LIBUUID_LIBS:-}"         \
        2>&1 | tee "${configure_log}"
    local _configure_exit="${PIPESTATUS[0]}"
    if [[ "$_configure_exit" -ne 0 ]]; then
        _die "configure failed (exit ${_configure_exit}) — see: ${configure_log}"
    fi
    _ok "configure finished."
}

# =============================================================================
# §13  POST-INSTALL
# =============================================================================
_post_install() {
    _info "Creating convenience symlinks ..."
    (
        cd "${TERMUX_PREFIX}/bin"
        ln -sf "idle${_MAJOR_VERSION}"         idle          2>/dev/null || true
        ln -sf "python${_MAJOR_VERSION}"        python        2>/dev/null || true
        ln -sf "python${_MAJOR_VERSION}-config" python-config 2>/dev/null || true
        ln -sf "pydoc${_MAJOR_VERSION}"         pydoc         2>/dev/null || true
    )
    if [[ -d "${TERMUX_PREFIX}/share/man/man1" ]]; then
        ln -sf "python${_MAJOR_VERSION}.1" \
               "${TERMUX_PREFIX}/share/man/man1/python.1" 2>/dev/null || true
    fi

    local debpython_src="${TERMUX_PKG_SRCDIR}/debpython/debpython"
    if [[ -d "$debpython_src" ]]; then
        local debpython_dst="${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/debpython"
        install -d -m 755 "$debpython_dst"
        install -m 644 "${debpython_src}/"* "$debpython_dst/"
        for prog in py3compile py3clean; do
            local prog_src="${TERMUX_PKG_SRCDIR}/debpython/${prog}"
            if [[ -f "$prog_src" ]]; then install -m 755 "$prog_src" "${TERMUX_PREFIX}/bin/"; fi
        done
        _ok "Installed debpython helpers."
    fi
    return 0
}

# =============================================================================
# §14  MODULE VERIFICATION
# =============================================================================
_verify_modules() {
    if [[ "$_OPT_SKIP_VERIFY" == "true" ]]; then
        _warn "Module verification skipped."; return
    fi
    _info "Verifying required extension modules ..."
    local python_bin="${TERMUX_PREFIX}/bin/python${_MAJOR_VERSION}"
    if [[ ! -x "$python_bin" ]]; then
        _warn "python${_MAJOR_VERSION} not executable at $python_bin — skipping verification."
        return
    fi
    local failed=0
    for mod in "${_REQUIRED_MODULES[@]}"; do
        if "$python_bin" -c "import ${mod}" 2>/dev/null; then
            _ok "  Module OK: ${mod}"
        else
            _error "Module missing: ${mod}"
            (( failed++ )) || true
        fi
    done
    local pyrepl_dir="${TERMUX_PREFIX}/${_PYREPL_SUBDIR}"
    if [[ -d "$pyrepl_dir" ]] && [[ -f "${pyrepl_dir}/__init__.py" ]]; then
        _ok "  Module OK: _pyrepl (pure Python, ${pyrepl_dir})"
    else
        _error "Module missing: _pyrepl — expected directory at ${pyrepl_dir}"
        (( failed++ )) || true
    fi
    if [[ "$failed" -ne 0 ]]; then _die "${failed} required module(s) missing."; fi
    _ok "All required modules present."
}

# =============================================================================
# §14b  PATCH _pyrepl FOR ANDROID COMPATIBILITY
# =============================================================================
# Python 3.13's _pyrepl package is pure Python but has two Android issues:
#
# 1. unix_console.py imports _curses unconditionally at module load time.
#    If _curses is absent, Python falls through to a Windows-only code path
#    and prints: "warning: can't use pyrepl: No module named 'msvcrt'"
#    (CPython issue #130046). This is fixed in 3.14 (issue #135621) but not
#    backported to 3.13. We apply the backport here: wrap the _curses import
#    in a try/except ImportError so it degrades gracefully to the basic REPL.
#
# 2. unix_console.py calls termios.tcsetattr() during prepare(); on some
#    Android environments this raises termios.error: (1, 'Operation not
#    permitted'). CPython 3.13.12 already fixed this via gh-134466.
#
# Uses Python (always available as the host build-python) for in-place edits
# so the replacement is portable across GNU sed and BSD sed.
_patch_pyrepl() {
    local unix_console="${TERMUX_PKG_SRCDIR}/Lib/_pyrepl/unix_console.py"
    local curses_py="${TERMUX_PKG_SRCDIR}/Lib/_pyrepl/curses.py"

    if [[ ! -f "$unix_console" ]]; then
        _warn "_patch_pyrepl: ${unix_console} not found — skipping."
        return 0
    fi

    # Use the host Python (guaranteed present — it's the --with-build-python)
    # for all source edits. Python's str.replace is byte-identical on every
    # platform, unlike sed whose \n behaviour differs between GNU and BSD.
    local _host_py
    _host_py="$(command -v "python${_MAJOR_VERSION}" || command -v python3)"

    # ── Patch 1 & 2: guard 'import _curses' in unix_console.py and curses.py ─
    # Replace the bare top-level import with a try/except ImportError block.
    # We operate on both files with the same helper.
    _guard_curses_import() {
        local _file="$1"
        [[ -f "$_file" ]] || return 0
        if ! grep -q '^import _curses' "$_file"; then
            _info "  $(basename "$_file"): _curses import already guarded or absent."
            return 0
        fi
        "$_host_py" - "$_file" << 'PYEOF'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
old = 'import _curses\n'
new = (
    'try:\n'
    '    import _curses\n'
    'except ImportError:\n'
    '    _curses = None  # type: ignore[assignment]  # pyrepl: Android/no-curses fallback\n'
)
text = path.read_text(encoding='utf-8')
if old not in text:
    sys.exit(0)
path.write_text(text.replace(old, new, 1), encoding='utf-8')
PYEOF
        _ok "  $(basename "$_file"): guarded _curses import."
    }

    _guard_curses_import "$unix_console"
    _guard_curses_import "$curses_py"

    # ── Patch 3: add _CURSES_AVAILABLE sentinel after the import block ────────
    # Only needed if the guard was actually inserted (i.e. _curses is now
    # conditionally imported). The sentinel is read by prepare() in some
    # Python 3.13 patch-level revisions; it is a no-op if already present.
    if grep -q 'except ImportError:' "$unix_console" && \
       ! grep -q '_CURSES_AVAILABLE' "$unix_console"; then
        "$_host_py" - "$unix_console" << 'PYEOF'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
old = (
    'except ImportError:\n'
    '    _curses = None  # type: ignore[assignment]  # pyrepl: Android/no-curses fallback\n'
)
new = old + '_CURSES_AVAILABLE = _curses is not None\n'
if '_CURSES_AVAILABLE' not in text:
    path.write_text(text.replace(old, new, 1), encoding='utf-8')
PYEOF
        _info "  unix_console.py: added _CURSES_AVAILABLE sentinel."
    else
        _info "  unix_console.py: _CURSES_AVAILABLE already present or not needed."
    fi

    _ok "_pyrepl patches applied."
    return 0
}

# =============================================================================
# §15  CREATE .deb PACKAGE
# =============================================================================
_create_deb() {
    _info "Creating .deb package ..."
    local debdir="${TERMUX_PKG_BUILDDIR}/deb"
    local pkgname="python"
    local arch
    case "$TERMUX_ARCH" in
        aarch64) arch="arm64" ;;
        arm)     arch="armhf" ;;
        i686)    arch="i386"  ;;
        x86_64)  arch="amd64" ;;
        *)       arch="$TERMUX_ARCH" ;;
    esac
    local debname="${pkgname}_${TERMUX_PKG_VERSION}-${TERMUX_PKG_REVISION}_${arch}.deb"

    local ctrl="${debdir}/DEBIAN"
    mkdir -p "$ctrl"

    cat > "${ctrl}/control" << EOF
Package: ${pkgname}
Version: ${TERMUX_PKG_VERSION}-${TERMUX_PKG_REVISION}
Architecture: ${arch}
Maintainer: ${TERMUX_PKG_MAINTAINER:-Termux}
Description: ${TERMUX_PKG_DESCRIPTION}
Homepage: ${TERMUX_PKG_HOMEPAGE}
EOF

    local _TERMUX_CANONICAL="data/data/com.termux/files/usr"
    local staging="${debdir}/${_TERMUX_CANONICAL}"
    mkdir -p "$staging"
    cp -a "${TERMUX_PREFIX}/." "$staging/"

    local _empty_count=0
    while IFS= read -r -d '' _f; do
        _warn "  Removing empty file from bin/: $(basename "$_f")"
        rm -f "$_f"
        (( _empty_count++ )) || true
    done < <(find "${staging}/bin" -maxdepth 1 -type f -empty -print0 2>/dev/null)
    if [[ "$_empty_count" -gt 0 ]]; then
        _warn "Removed ${_empty_count} empty file(s) from bin/ before packaging."
    else
        _info "bin/ is clean — no empty files found."
    fi

    local _p="/${_TERMUX_CANONICAL}"
    local postinst="${ctrl}/postinst"
    {
        printf '#!/usr/bin/env bash\nset -e\n\n'
        printf '_pip_managed_by_pkg() {\n'
        printf '    case "${TERMUX_PACKAGE_FORMAT:-debian}" in\n'
        printf '        debian) [[ -f "%s/var/lib/dpkg/info/python-pip.list" ]] ;;\n'      "${_p}"
        printf '        pacman) ls "%s/var/lib/pacman/local/python-pip-"* &>/dev/null ;;\n' "${_p}"
        printf '        *)      return 1 ;;\n'
        printf '    esac\n}\n\n'
        printf 'if [[ -f "%s/bin/pip" ]] && ! _pip_managed_by_pkg; then\n'                 "${_p}"
        printf '    echo "Removing unmanaged pip..."\n'
        printf '    rm -f "%s/bin/pip" "%s/bin/pip3"* "%s/bin/easy_install"*\n'            "${_p}" "${_p}" "${_p}"
        printf '    rm -rf "%s/lib/python%s/site-packages/pip"*\n'                         "${_p}" "${_MAJOR_VERSION}"
        printf 'fi\n\n'
        printf 'if [[ ! -f "%s/bin/pip" ]]; then\n'                                        "${_p}"
        printf '    echo "== Note: pip is now a separate package: pkg install python-pip =="\n'
        printf 'fi\n\n'
        printf 'for _old_ver in 3.11 3.12; do\n'
        printf '    if [[ -d "%s/lib/python${_old_ver}/site-packages" ]]; then\n'          "${_p}"
        printf '        echo "NOTE: Python updated to %s. Reinstall pip packages."\n'       "${_MAJOR_VERSION}"
        printf '        break\n'
        printf '    fi\n'
        printf 'done\nexit 0\n'
    } > "$postinst"
    chmod 0755 "$postinst"
    bash -n "$postinst" || _die "Generated postinst has syntax errors."

    mkdir -p "$OUTPUT_DIR"
    local debout="${OUTPUT_DIR}/${debname}"

    if command -v dpkg-deb &>/dev/null; then
        dpkg-deb --build "$debdir" "$debout"
    else
        _warn "dpkg-deb not available; building .deb manually ..."
        local tmp; tmp="$(mktemp -d)"
        # Register cleanup immediately so partial builds don't leak the temp dir.
        # trap EXIT fires even when _die is called; it does not conflict with
        # set -u because $tmp is assigned before the trap is installed.
        trap 'rm -rf "${tmp:-}"' EXIT

        echo "2.0" > "${tmp}/debian-binary"

        tar -czf "${tmp}/control.tar.gz" -C "$ctrl" . \
            || _die "control.tar.gz creation failed."

        tar -cf "${tmp}/data.tar" --exclude='./DEBIAN' -C "$debdir" . \
            || _die "data.tar creation failed."
        xz -z -T0 "${tmp}/data.tar" \
            || _die "xz compression of data.tar failed."

        # Prefer llvm-ar (already on PATH from the NDK toolchain) over the
        # system ar, which may be BSD ar with subtly different flag syntax.
        local _deb_ar
        if command -v llvm-ar &>/dev/null; then
            _deb_ar="llvm-ar"
        elif command -v gar &>/dev/null; then
            _deb_ar="gar"   # Homebrew gnu-ar on some macOS setups
        else
            _deb_ar="ar"
        fi

        "${_deb_ar}" rcs "$debout" \
            "${tmp}/debian-binary" \
            "${tmp}/control.tar.gz" \
            "${tmp}/data.tar.xz" \
            || _die "${_deb_ar}: failed assembling .deb."

        rm -rf "$tmp"
        trap - EXIT   # clear the trap once the temp dir is gone
    fi

    local size; size="$(du -sh "$debout" | cut -f1)"
    _ok "Package: ${debout}  (${size})"
    echo "$debout"
}

# =============================================================================
# §16  MAIN
# =============================================================================
main() {
    _parse_args "$@"
    _setup_env

    _section "Termux Python ${TERMUX_PKG_VERSION} — Build for Android"
    printf "  %-20s %s\n" "Version:"      "${TERMUX_PKG_VERSION} (rev ${TERMUX_PKG_REVISION})"
    printf "  %-20s %s\n" "API Level:"    "${TERMUX_PKG_API_LEVEL}"
    printf "  %-20s %s\n" "Arch:"         "${TERMUX_ARCH}"
    printf "  %-20s %s\n" "Host triple:"  "${TERMUX_HOST_PLATFORM}"
    printf "  %-20s %s\n" "Build triple:" "${TERMUX_BUILD_TUPLE}"
    printf "  %-20s %s\n" "Prefix:"       "${TERMUX_PREFIX}"
    printf "  %-20s %s\n" "On-device:"    "${TERMUX_ON_DEVICE_BUILD}"
    printf "  %-20s %s\n" "CPU_COUNT:"    "${CPU_COUNT}"
    printf "  %-20s %s\n" "Make jobs:"    "${TERMUX_PKG_MAKE_PROCESSES}"
    printf "  %-20s %s\n" "LTO:"          "${_OPT_LTO}"
    printf "  %-20s %s\n" "PGO:"          "${_OPT_PGO}"
    printf "  %-20s %s\n" "No-deb:"       "${_OPT_NO_DEB}"
    printf "  %-20s %s\n" "Keep-tests:"   "${_OPT_KEEP_TESTS}"
    printf "  %-20s %s\n" "Skip-verify:"  "${_OPT_SKIP_VERIFY}"
    printf "  %-20s %s\n" "Source URL:"   "${PATCHED_SOURCE_URL}"
    echo

    _section "Step 1/12 — Tool Check"
    _check_tools

    if [[ "$_OPT_CLEAN" == "true" ]]; then
        _section "Step 2/12 — Clean"
        rm -rf "$TERMUX_PKG_SRCDIR" "$TERMUX_PKG_BUILDDIR"
        _ok "Clean complete."
    else
        _info "Step 2/12 — Clean skipped (pass --clean to wipe build dirs)."
    fi

    _section "Step 3/12 — Download Patched Source"
    mkdir -p "$TERMUX_PKG_CACHEDIR" "$TERMUX_PKG_SRCDIR"
    _download "${PATCHED_SOURCE_URL}" "${TERMUX_PKG_CACHEDIR}/${_PATCHED_TARBALL}"

    _section "Step 4/12 — Unpack Patched Source"
    _info "Unpacking ${_PATCHED_TARBALL} ..."
    rm -rf "$TERMUX_PKG_SRCDIR"
    mkdir -p "$TERMUX_PKG_SRCDIR"
    tar -xJf "${TERMUX_PKG_CACHEDIR}/${_PATCHED_TARBALL}" \
        --strip-components=1 -C "$TERMUX_PKG_SRCDIR" \
        || _die "Failed to unpack patched source tarball."
    _ok "Patched source unpacked."

    _section "Step 4b/12 — Patch _pyrepl for Android compatibility"
    _patch_pyrepl

    _section "Step 5/12 — Setup Compiler Flags"
    _setup_flags

    _section "Step 5b/12 — LTO / PGO Setup"
    _setup_lto_pgo

    _section "Step 6/12 — Cross-Compile Dependencies"
    _build_deps

    _section "Step 7/12 — Configure"
    _do_configure

    _section "Step 8/12 — Build"
    _info "make -j${TERMUX_PKG_MAKE_PROCESSES} ..."
    cd "$TERMUX_PKG_BUILDDIR"
    make -j"${TERMUX_PKG_MAKE_PROCESSES}" \
        CPPFLAGS="${CPPFLAGS}" \
        LDFLAGS="${LDFLAGS} ${PYTHON_EXTRA_LDFLAGS:-}" \
        || _die "make failed."
    _ok "Build complete."

    _section "Step 9/12 — Install"
    make install || _die "make install failed."
    _ok "Install complete."

    _section "Step 10/12 — Post-Install + Module Verification"
    _post_install
    _verify_modules

    _section "Step 11/12 — Package"
    if [[ "$_OPT_KEEP_TESTS" != "true" ]]; then
        _info "Removing test trees ..."
        rm -rf \
            "${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/test"    \
            "${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/"*/test  \
            "${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/"*/tests
    else
        _warn "Keeping test trees (--keep-tests)."
    fi

    shopt -s nullglob
    local -a sp_files=("${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/site-packages/"*)
    shopt -u nullglob
    if [[ "${#sp_files[@]}" -gt 0 ]]; then rm -rf "${sp_files[@]}"; fi

    if [[ "$_OPT_NO_DEB" == "true" ]]; then
        _warn "--no-deb set; skipping .deb packaging."
        _section "Build Successful (no package)"
        printf "  Python %s installed to: %s\n\n" "${TERMUX_PKG_VERSION}" "${TERMUX_PREFIX}"
        return
    fi

    _section "Step 12/12 — Create .deb"
    local debfile
    debfile="$(_create_deb)"

    _section "Build Successful"
    printf "  Python %s installed to : %s\n"   "${TERMUX_PKG_VERSION}" "${TERMUX_PREFIX}"
    printf "  .deb package           : %s\n"   "${debfile}"
    printf "  LTO                    : %s\n"   "${_OPT_LTO}"
    printf "  PGO                    : %s\n\n" "${_OPT_PGO}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
