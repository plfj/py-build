#!/usr/bin/env bash
# =============================================================================
# Termux Python 3.14.3 — build-pkg.sh
# =============================================================================
# PART 2 OF 2: Download the patched + autoreconf'd source tarball produced by
# prepare-source.sh, cross-compile Python for Android, and produce a .deb
# package for Termux.
#
# Usage:
#   bash build-pkg.sh [OPTIONS]
#
# Options:
#   -h, --help              Show this help and exit
#       --clean             Wipe build/src dirs before starting
#       --skip-verify       Skip post-install module verification
#       --no-deb            Build and install only; skip .deb packaging
#       --keep-tests        Do not strip test directories from the install tree
#       --no-deps           Skip cross-compiling bzip2/xz/sqlite/openssl;
#                           use whatever is already in CROSS_DEPS_PREFIX
#       --resume            Re-use an existing build dir (skip unpack+configure;
#                           run make + install only) — useful when iterating
#                           on Makefile-level failures
#       --free-threaded     Enable the experimental no-GIL build (PEP 703).
#                           Adds --disable-gil to configure. Native extensions
#                           must be rebuilt separately for this to work.
#       --jobs N            Override parallel make job count
#       --output-dir PATH   Where to write the final .deb
#                           (default: $OUTPUT_DIR or directory of this script)
#       --workdir PATH      Override the build working directory
#                           (default: $TMPDIR/python-build)
#
# Environment variables (all auto-detected when not set):
#   PATCHED_SOURCE_URL          URL to python-*-patched-src.tar.xz  [required]
#   TERMUX_PREFIX               Install prefix
#   TERMUX_ARCH                 Target arch: aarch64|arm|i686|x86_64
#   TERMUX_PKG_API_LEVEL        Android API level (default: 35)
#   TERMUX_STANDALONE_TOOLCHAIN NDK toolchain root
#   TERMUX_HOST_PLATFORM        Cross-compile host triple (auto-derived)
#   TERMUX_BUILD_TUPLE          Build-machine triple (auto-derived)
#   TERMUX_ON_DEVICE_BUILD      true|false (auto-detected)
#   TERMUX_PACKAGE_FORMAT       debian|pacman (default: debian)
#   CPU_COUNT / TERMUX_PKG_MAKE_PROCESSES   Parallel jobs
#   OUTPUT_DIR                  Where to write the final .deb
#   CONF_CACHE / CONF_FLAGS     Extra autoconf cache vars / configure flags
#   CROSS_DEPS_PREFIX           Where cross-compiled deps are installed
#   CC, CXX, AR, AS, LD, NM, RANLIB, STRIP, OBJDUMP
#   CFLAGS, CXXFLAGS, LDFLAGS, SYSROOT, ANDROID_NDK_HOME
#
# Output:
#   Populated $TERMUX_PREFIX tree
#   $OUTPUT_DIR/python_3.14.3-0_arm64.deb  (arch suffix varies)
#   $OUTPUT_DIR/python_3.14.3-0_arm64.deb.sha256
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
    printf '\n\033[1;31m[FATAL]\033[0m  build-pkg.sh aborted at line %s (exit %s)\n' \
        "$line" "$code" >&2
    printf '        Check logs in: %s\n' \
        "${TERMUX_PKG_LOGDIR:-/tmp/python-build/logs}" >&2
    exit "$code"
}
trap '_err_trap' ERR

# =============================================================================
# §1  PACKAGE CONSTANTS  (keep in sync with prepare-source.sh)
# =============================================================================
readonly TERMUX_PKG_HOMEPAGE="https://python.org/"
readonly TERMUX_PKG_DESCRIPTION="Python 3 programming language intended to enable clear programs"
readonly TERMUX_PKG_LICENSE="PythonPL"
readonly TERMUX_PKG_MAINTAINER="@termux"
readonly TERMUX_PKG_VERSION="3.14.3"
readonly TERMUX_PKG_REVISION=0
readonly _MAJOR_VERSION="${TERMUX_PKG_VERSION%.*}"   # 3.14
readonly _PATCHED_TARBALL="python-${TERMUX_PKG_VERSION}-patched-src.tar.xz"

# Required extension modules verified post-install (on-device builds only).
# _interpchannels + _interpqueues are new in Python 3.14 (PEP 734).
readonly -a _REQUIRED_MODULES=(
    _bz2 _ctypes _curses _lzma _sqlite3 _ssl zlib
    _interpchannels _interpqueues
)
readonly _PYREPL_SUBDIR="lib/python${_MAJOR_VERSION}/_pyrepl"

# =============================================================================
# §2  OPTION FLAGS
# =============================================================================
_OPT_CLEAN=false
_OPT_SKIP_VERIFY=false
_OPT_NO_DEB=false
_OPT_KEEP_TESTS=false
_OPT_NO_DEPS=false
_OPT_RESUME=false
_OPT_FREE_THREADED=false
_OPT_JOBS=""
_OPT_OUTPUT_DIR="${OUTPUT_DIR:-${_SCRIPT_DIR}}"
_OPT_WORKDIR=""

# =============================================================================
# §3  LOGGING  (timestamped, colour-aware)
# =============================================================================
if [[ -t 2 ]]; then
    _CR='\033[0m' _BLU='\033[1;34m' _GRN='\033[1;32m'
    _YLW='\033[1;33m' _RED='\033[1;31m' _CYN='\033[1;36m'
else
    _CR='' _BLU='' _GRN='' _YLW='' _RED='' _CYN=''
fi
_ts()      { date '+%H:%M:%S'; }
_info()    { printf "${_BLU}[%s INFO ]${_CR}  %s\n"  "$(_ts)" "$*";     }
_ok()      { printf "${_GRN}[%s  OK  ]${_CR}  %s\n"  "$(_ts)" "$*";     }
_warn()    { printf "${_YLW}[%s WARN ]${_CR}  %s\n"  "$(_ts)" "$*" >&2; }
_error()   { printf "${_RED}[%s ERROR]${_CR}  %s\n"  "$(_ts)" "$*" >&2; }
_die()     { _error "$*"; exit 1;                                         }
_section() {
    local s="══════════════════════════════════════════════════════════════"
    printf "\n${_CYN}%s\n  %s\n%s${_CR}\n\n" "$s" "$*" "$s"
}

# =============================================================================
# §4  ARGUMENT PARSING
# =============================================================================
_parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                sed -n '/^# Usage:/,/^# ====/{ /^# ====/d; s/^# \{0,2\}//; p }' \
                    "$_SCRIPT_PATH"; exit 0 ;;
            --clean)         _OPT_CLEAN=true ;;
            --skip-verify)   _OPT_SKIP_VERIFY=true ;;
            --no-deb)        _OPT_NO_DEB=true ;;
            --keep-tests)    _OPT_KEEP_TESTS=true ;;
            --no-deps)       _OPT_NO_DEPS=true ;;
            --resume)        _OPT_RESUME=true ;;
            --free-threaded) _OPT_FREE_THREADED=true ;;
            --jobs|-j)
                [[ -n "${2:-}" && "$2" =~ ^[1-9][0-9]*$ ]] \
                    || _die "--jobs requires a positive integer"
                _OPT_JOBS="$2"; shift ;;
            --output-dir)
                [[ -n "${2:-}" ]] || _die "--output-dir requires a path"
                _OPT_OUTPUT_DIR="$2"; shift ;;
            --workdir)
                [[ -n "${2:-}" ]] || _die "--workdir requires a path"
                _OPT_WORKDIR="$2"; shift ;;
            *) _die "Unknown option: '$1'  (try --help)" ;;
        esac
        shift
    done
}

# =============================================================================
# §5  ARCH HELPERS
# =============================================================================
_normalize_arch() {
    case "$1" in arm64) echo "aarch64";; armv[678]l) echo "arm";; *) echo "$1";; esac
}
_arch_to_triplet() {
    case "$1" in
        aarch64) echo "aarch64-linux-android"  ;;
        arm)     echo "arm-linux-androideabi"  ;;
        i686)    echo "i686-linux-android"     ;;
        x86_64)  echo "x86_64-linux-android"  ;;
        *) _die "Unsupported TERMUX_ARCH: '$1'" ;;
    esac
}
_arch_to_deb() {
    case "$1" in aarch64) echo "arm64";; arm) echo "armhf";; i686) echo "i386";;
                 x86_64) echo "amd64";; *) echo "$1";; esac
}

# =============================================================================
# §6  CPU COUNT
# =============================================================================
_detect_cpu_count() {
    [[ -n "${CPU_COUNT:-}" ]] && { _info "CPU_COUNT=${CPU_COUNT} (env)"; return; }
    local n=4
    if   command -v nproc  &>/dev/null; then n="$(nproc)"
    elif command -v sysctl &>/dev/null; then n="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    elif [[ -r /proc/cpuinfo ]];        then n="$(grep -c '^processor' /proc/cpuinfo || echo 4)"
    fi
    CPU_COUNT="$n"; export CPU_COUNT
    _info "CPU_COUNT=${CPU_COUNT} (auto-detected)"
}

# =============================================================================
# §7  CROSS-COMPILE DETECTION
# =============================================================================
_is_cross_compiling() { [[ "$TERMUX_ON_DEVICE_BUILD" != "true" ]]; }

# =============================================================================
# §8  ENVIRONMENT DETECTION + DEFAULTS
# =============================================================================
_setup_env() {
    [[ -z "${TERMUX_PREFIX:-}" ]] && \
        export TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
    [[ -z "${TERMUX_PKG_API_LEVEL:-}" ]] && export TERMUX_PKG_API_LEVEL=35
    [[ -z "${TERMUX_ARCH:-}" ]] && TERMUX_ARCH="$(uname -m)"
    TERMUX_ARCH="$(_normalize_arch "$TERMUX_ARCH")"; export TERMUX_ARCH
    [[ -z "${TERMUX_STANDALONE_TOOLCHAIN:-}" ]] && \
        export TERMUX_STANDALONE_TOOLCHAIN="${TERMUX_PREFIX}"
    [[ -z "${TERMUX_PACKAGE_FORMAT:-}" ]] && export TERMUX_PACKAGE_FORMAT="debian"

    if [[ -z "${TERMUX_ON_DEVICE_BUILD:-}" ]]; then
        if [[ "$(uname -o 2>/dev/null)" == "Android" ]] || \
           [[ -e "/system/bin/app_process" ]]; then
            export TERMUX_ON_DEVICE_BUILD=true
        else
            export TERMUX_ON_DEVICE_BUILD=false
        fi
    fi

    [[ -z "${TERMUX_HOST_PLATFORM:-}" ]] && \
        { TERMUX_HOST_PLATFORM="$(_arch_to_triplet "$TERMUX_ARCH")"; \
          export TERMUX_HOST_PLATFORM; }

    if [[ -z "${TERMUX_BUILD_TUPLE:-}" ]]; then
        if [[ "$TERMUX_ON_DEVICE_BUILD" == "true" ]]; then
            TERMUX_BUILD_TUPLE="$(_arch_to_triplet "$TERMUX_ARCH")"
        else
            local _h; _h="$(_normalize_arch "$(uname -m)")"
            case "$(uname -s)" in
                Darwin) TERMUX_BUILD_TUPLE="${_h}-apple-darwin"  ;;
                *)      TERMUX_BUILD_TUPLE="${_h}-linux-gnu"     ;;
            esac
        fi
        export TERMUX_BUILD_TUPLE
    fi

    _detect_cpu_count
    if [[ -n "$_OPT_JOBS" ]]; then
        TERMUX_PKG_MAKE_PROCESSES="$_OPT_JOBS"
    elif [[ -z "${TERMUX_PKG_MAKE_PROCESSES:-}" ]]; then
        TERMUX_PKG_MAKE_PROCESSES="$CPU_COUNT"
    fi
    export TERMUX_PKG_MAKE_PROCESSES

    # Cross-compile auto-skips module verification
    if _is_cross_compiling && [[ "$_OPT_SKIP_VERIFY" != "true" ]]; then
        _warn "Cross-compile detected — module verification auto-skipped."
        _OPT_SKIP_VERIFY=true
    fi

    local _wb="${_OPT_WORKDIR:-${TMPDIR:-/tmp}/python-build}"
    TERMUX_PKG_SRCDIR="${_wb}/src"
    TERMUX_PKG_BUILDDIR="${_wb}/build"
    TERMUX_PKG_CACHEDIR="${_wb}/cache"
    TERMUX_PKG_LOGDIR="${_wb}/logs"
    OUTPUT_DIR="$_OPT_OUTPUT_DIR"
    export TERMUX_PKG_SRCDIR TERMUX_PKG_BUILDDIR \
           TERMUX_PKG_CACHEDIR TERMUX_PKG_LOGDIR OUTPUT_DIR

    # Sanitise PATCHED_SOURCE_URL (GitHub Actions may inject __ artefacts)
    PATCHED_SOURCE_URL="${PATCHED_SOURCE_URL:-}"
    PATCHED_SOURCE_URL="${PATCHED_SOURCE_URL#__}"; PATCHED_SOURCE_URL="${PATCHED_SOURCE_URL%__}"
    PATCHED_SOURCE_URL="${PATCHED_SOURCE_URL// /}"; export PATCHED_SOURCE_URL
    [[ -n "$PATCHED_SOURCE_URL" ]] \
        || _die "PATCHED_SOURCE_URL is not set."
    [[ "$PATCHED_SOURCE_URL" == http://* || "$PATCHED_SOURCE_URL" == https://* ]] \
        || _die "PATCHED_SOURCE_URL is not an HTTP(S) URL: '$PATCHED_SOURCE_URL'"
    _info "Source URL: $PATCHED_SOURCE_URL"
}

# =============================================================================
# §9  SHA256 + DOWNLOAD
# =============================================================================
_sha256() {
    if command -v sha256sum &>/dev/null; then sha256sum "$1" | awk '{print $1}'
    elif command -v shasum  &>/dev/null; then shasum -a 256 "$1" | awk '{print $1}'
    else _die "No SHA-256 tool found."; fi
}

_download() {
    local url="$1" dest="$2" expected="${3:-}"
    local tmp="${dest}.tmp.$$" name; name="$(basename "$dest")"
    mkdir -p "$(dirname "$dest")"
    if [[ -f "$dest" ]]; then
        local actual; actual="$(_sha256 "$dest")"
        if [[ -z "$expected" || "$actual" == "$expected" ]]; then
            _ok "Cache hit: $name"; return 0
        fi
        _warn "Cache checksum mismatch — re-downloading $name"; rm -f "$dest"
    fi
    _info "Downloading: $name"
    local -a dl=()
    if command -v curl &>/dev/null; then
        dl=(curl --fail --location --retry 5 --retry-delay 3 --retry-all-errors
                 --connect-timeout 30 --progress-bar --output "$tmp" -- "$url")
    elif command -v wget &>/dev/null; then
        dl=(wget --tries=5 --timeout=30 --waitretry=3
                 --show-progress --quiet --output-document="$tmp" -- "$url")
    else _die "Neither curl nor wget found."; fi
    "${dl[@]}" || { rm -f "$tmp"; _die "Download failed: $url"; }
    if [[ -n "$expected" ]]; then
        local actual; actual="$(_sha256 "$tmp")"
        [[ "$actual" == "$expected" ]] \
            || { rm -f "$tmp"; _die "SHA256 mismatch: expected=$expected got=$actual"; }
    fi
    mv "$tmp" "$dest"
    _ok "Downloaded: $name  ($(du -sh "$dest" | cut -f1))"
}

# =============================================================================
# §10  TOOL CHECK
# =============================================================================
_check_tools() {
    _info "Checking required build tools ..."
    local -a req=(make tar pkg-config perl gawk ar zstd xz)
    local missing=0
    command -v clang &>/dev/null || command -v gcc &>/dev/null || req+=(clang)
    command -v curl  &>/dev/null || command -v wget &>/dev/null || req+=(curl)
    for t in "${req[@]}"; do
        if command -v "$t" &>/dev/null; then _info "  OK: $t → $(command -v "$t")"
        else _error "Missing: $t"; (( missing++ )) || true; fi
    done
    [[ "$missing" -ne 0 ]] && _die "${missing} required tool(s) missing."
    _ok "All required tools present."
}

# =============================================================================
# §11  PRE-CONFIGURE FLAGS
# =============================================================================
_setup_flags() {
    unset PKG_CONFIG_PATH CPPFLAGS_HOST LDFLAGS_HOST 2>/dev/null || true

    # Find a host Python >= 3.11 for the freeze/bootstrap step
    local _BUILD_PYTHON=""
    for _c in "python${_MAJOR_VERSION}" "python3" "python3.13" "python3.12" "python3.11"; do
        if command -v "$_c" &>/dev/null; then
            if "$_c" -c "import sys; exit(0 if sys.version_info>=(3,11) else 1)" 2>/dev/null; then
                _BUILD_PYTHON="$(command -v "$_c")"; break
            fi
        fi
    done
    [[ -n "$_BUILD_PYTHON" ]] || {
        _warn "No host Python >= 3.11 found — configure may fail at freeze step."
        _BUILD_PYTHON="python${_MAJOR_VERSION}"
    }
    _info "Host Python (--with-build-python): $_BUILD_PYTHON"

    # CFLAGS
    CFLAGS="${CFLAGS:-}"
    CFLAGS="${CFLAGS/-Oz/-O3}"
    [[ "$CFLAGS" =~ -O[0-9s] ]] || CFLAGS+=" -O3"
    CFLAGS+=" -fno-semantic-interposition"
    [[ -n "${SYSROOT:-}" && "$CFLAGS" != *--sysroot* ]] && CFLAGS+=" --sysroot=${SYSROOT}"
    [[ -n "${ANDROID_BUILD_TARGET:-}" && "$CFLAGS" != *-target* ]] && \
        CFLAGS+=" -target ${ANDROID_BUILD_TARGET}"

    # LDFLAGS
    LDFLAGS="${LDFLAGS:-}"
    LDFLAGS="${LDFLAGS//-Wl,--as-needed/}"
    [[ -n "${SYSROOT:-}" && "$LDFLAGS" != *--sysroot* ]] && LDFLAGS+=" --sysroot=${SYSROOT}"
    [[ "$LDFLAGS" == *-fuse-ld* ]] || LDFLAGS+=" -fuse-ld=lld"

    # CPPFLAGS + NDK sysroot paths
    CPPFLAGS="${CPPFLAGS:-}"
    local _sr="${TERMUX_STANDALONE_TOOLCHAIN}/sysroot"
    local _si="${_sr}/usr/include"
    local _slb="${_sr}/usr/lib"
    local _sla="${_slb}/${TERMUX_HOST_PLATFORM}"
    local _slapi="${_sla}/${TERMUX_PKG_API_LEVEL}"
    if [[ -d "$_si" ]]; then
        CPPFLAGS+=" -I${_si}"
        [[ -d "${_si}/${TERMUX_HOST_PLATFORM}" ]] && CPPFLAGS+=" -I${_si}/${TERMUX_HOST_PLATFORM}"
    fi
    for _ld in "$_slapi" "$_sla" "$_slb"; do
        [[ -d "$_ld" ]] && LDFLAGS+=" -L${_ld}"
    done
    if [[ "$TERMUX_ON_DEVICE_BUILD" == "true" ]]; then
        local sdk; sdk="$(getprop ro.build.version.sdk 2>/dev/null || echo "${TERMUX_PKG_API_LEVEL}")"
        CPPFLAGS+=" -D__ANDROID_API__=${sdk}"
    fi

    # autoconf cache vars
    CONF_CACHE="${CONF_CACHE:-}"
    CONF_CACHE+=" ac_cv_file__dev_ptmx=yes ac_cv_file__dev_ptc=no"
    CONF_CACHE+=" ac_cv_func_wcsftime=no ac_cv_func_ftime=no"
    CONF_CACHE+=" ac_cv_func_faccessat=no ac_cv_func_linkat=no"
    CONF_CACHE+=" ac_cv_buggy_getaddrinfo=no ac_cv_little_endian_double=yes"
    CONF_CACHE+=" ac_cv_posix_semaphores_enabled=yes"
    # Patch 0005 unblocks sem_open/sem_unlink in configure.ac
    CONF_CACHE+=" ac_cv_func_sem_open=yes ac_cv_func_sem_timedwait=yes"
    CONF_CACHE+=" ac_cv_func_sem_getvalue=yes ac_cv_func_sem_unlink=yes"
    CONF_CACHE+=" ac_cv_func_shm_open=yes ac_cv_func_shm_unlink=yes"
    CONF_CACHE+=" ac_cv_working_tzset=yes ac_cv_header_sys_xattr_h=no"
    CONF_CACHE+=" ac_cv_func_getgrent=yes"
    CONF_CACHE+=" ac_cv_func_posix_spawn=yes ac_cv_func_posix_spawnp=yes"
    CONF_CACHE+=" ac_cv_func_pthread_getname_np=yes ac_cv_func_pthread_setname_np=yes"

    # configure feature flags
    CONF_FLAGS="${CONF_FLAGS:-}"
    CONF_FLAGS+=" --with-build-python=${_BUILD_PYTHON}"
    CONF_FLAGS+=" --with-system-ffi --without-static-libpython --with-lto"
    CONF_FLAGS+=" --without-ensurepip --enable-loadable-sqlite-extensions"
    CONF_FLAGS+=" --with-android-api-level=${TERMUX_PKG_API_LEVEL}"
    if [[ "$_OPT_FREE_THREADED" == "true" ]]; then
        _warn "Free-threaded build (--disable-gil / PEP 703) enabled."
        CONF_FLAGS+=" --disable-gil"
    fi

    # API-level-gated cache vars
    local api="${TERMUX_PKG_API_LEVEL}"
    (( api < 28 )) && CONF_CACHE+=" ac_cv_func_fexecve=no ac_cv_func_getlogin_r=no"
    (( api < 29 )) && CONF_CACHE+=" ac_cv_func_getloadavg=no"
    (( api < 30 )) && CONF_CACHE+=" ac_cv_func_sem_clockwait=no ac_cv_func_memfd_create=no"
    (( api < 31 )) && CONF_CACHE+=" ac_cv_func_pidfd_getfd=no ac_cv_func_process_madvise=no"
    (( api < 33 )) && CONF_CACHE+=" ac_cv_func_preadv2=no ac_cv_func_pwritev2=no"
    (( api < 34 )) && {
        CONF_CACHE+=" ac_cv_func_close_range=no ac_cv_func_copy_file_range=no"
        CONF_CACHE+=" ac_cv_func_posix_spawn_file_actions_addchdir_np=no"
        CONF_CACHE+=" ac_cv_func_posix_spawn_file_actions_addfchdir_np=no"
    }
    (( api < 35 )) && \
        CONF_CACHE+=" ac_cv_func_epoll_pwait2=no ac_cv_func_tcgetwinsize=no ac_cv_func_tcsetwinsize=no"
    (( api < 36 )) && {
        CONF_CACHE+=" ac_cv_func_qsort_r=no"
        CONF_CACHE+=" ac_cv_func_pthread_getaffinity_np=no ac_cv_func_pthread_setaffinity_np=no"
    }

    # Polyfill libraries
    PYTHON_EXTRA_LDFLAGS=""
    if (( api < 30 )); then
        if [[ -f "${TERMUX_PREFIX}/lib/libandroid-posix-semaphore.a" ]] || \
           [[ -f "${TERMUX_PREFIX}/lib/libandroid-posix-semaphore.so" ]]; then
            PYTHON_EXTRA_LDFLAGS+=" -landroid-posix-semaphore"
            LDFLAGS+=" -L${TERMUX_PREFIX}/lib"
        else _warn "libandroid-posix-semaphore not found (API ${api})"; fi
    fi
    if (( api < 28 )); then
        if [[ -f "${TERMUX_PREFIX}/lib/libandroid-spawn.a" ]] || \
           [[ -f "${TERMUX_PREFIX}/lib/libandroid-spawn.so" ]]; then
            PYTHON_EXTRA_LDFLAGS+=" -landroid-spawn"
        else _warn "libandroid-spawn not found (API ${api})"; fi
    fi
    export PYTHON_EXTRA_LDFLAGS

    if [[ "$TERMUX_ON_DEVICE_BUILD" == "true" ]] || \
       [[ -f "${TERMUX_PREFIX}/lib/libcrypt.a" ]] || \
       [[ -f "${TERMUX_PREFIX}/lib/libcrypt.so" ]]; then
        export LIBCRYPT_LIBS="-lcrypt"
    else export LIBCRYPT_LIBS=""; fi

    export CFLAGS CPPFLAGS LDFLAGS CONF_CACHE CONF_FLAGS
}

# =============================================================================
# §11b  CROSS-COMPILE DEPENDENCIES
# =============================================================================
readonly _BZIP2_VERSION="1.0.8"
readonly _XZ_VERSION="5.6.3"
readonly _SQLITE_VERSION="3490100"; readonly _SQLITE_YEAR="2025"
readonly _OPENSSL_VERSION="3.4.1"
readonly _LIBFFI_VERSION="3.4.7-1"
readonly _LIBFFI_BASE="https://packages.termux.dev/apt/termux-main/pool/main/libf/libffi"
readonly _NCURSES_VER="6.6.20260124+really6.5.20250830"
readonly _NCURSES_VER_URL="6.6.20260124%2Breally6.5.20250830"
readonly _NCURSES_BASE="https://packages.termux.dev/apt/termux-main/pool/main/n"

_dl_extract() {
    local url="$1" tarball="$2" dir="$3"
    _download "$url" "${TERMUX_PKG_CACHEDIR}/${tarball}"
    [[ -d "$dir" ]] && { _info "  Already extracted: $(basename "$dir")"; return 0; }
    mkdir -p "$(dirname "$dir")"
    case "$tarball" in
        *.tar.xz)       tar -xJf "${TERMUX_PKG_CACHEDIR}/${tarball}" -C "$(dirname "$dir")" ;;
        *.tar.gz|*.tgz) tar -xzf "${TERMUX_PKG_CACHEDIR}/${tarball}" -C "$(dirname "$dir")" ;;
        *.tar.bz2)      tar -xjf "${TERMUX_PKG_CACHEDIR}/${tarball}" -C "$(dirname "$dir")" ;;
        *)               _die "Unknown archive type: $tarball" ;;
    esac
}

_extract_deb() {
    local deb="$1" dest="$2"
    local tmp="${dest}/_deb_$$"; mkdir -p "$tmp"
    ( cd "$tmp"; ar x "$deb"
      local dt; dt="$(ls data.tar.* 2>/dev/null | head -1)"
      [[ -n "$dt" ]] || _die "No data.tar.* in $(basename "$deb")"
      case "$dt" in
          *.xz)  tar -xJf "$dt" -C "$dest" ;;
          *.gz)  tar -xzf "$dt" -C "$dest" ;;
          *.zst) zstd -d  "$dt" --stdout | tar -x -C "$dest" ;;
          *)     _die "Unknown deb data format: $dt" ;;
      esac )
    rm -rf "$tmp"
}

_point_build_at_deps() {
    CPPFLAGS+=" -I${CROSS_DEPS_PREFIX}/include"
    LDFLAGS+=" -L${CROSS_DEPS_PREFIX}/lib"
    export PKG_CONFIG_PATH="${CROSS_DEPS_PREFIX}/lib/pkgconfig"
    export PKG_CONFIG_LIBDIR="${CROSS_DEPS_PREFIX}/lib/pkgconfig"
    export CPPFLAGS LDFLAGS
    CONF_FLAGS+=" CURSES_CFLAGS=-I${CROSS_DEPS_PREFIX}/include/ncursesw"
    CONF_FLAGS+=" CURSES_LIBS=-lncursesw PANEL_LIBS=-lpanelw"
    export CONF_FLAGS
    _ok "Dependencies ready at: ${CROSS_DEPS_PREFIX}"
}

_build_deps() {
    if [[ "$_OPT_NO_DEPS" == "true" ]]; then
        _warn "--no-deps: skipping dep builds."
        CROSS_DEPS_PREFIX="${CROSS_DEPS_PREFIX:-${TERMUX_PREFIX}}"
        export CROSS_DEPS_PREFIX; _point_build_at_deps; return 0
    fi
    if [[ "$TERMUX_ON_DEVICE_BUILD" == "true" ]]; then
        _info "On-device build — using installed Termux packages."
        CROSS_DEPS_PREFIX="${TERMUX_PREFIX}"; export CROSS_DEPS_PREFIX
        _point_build_at_deps; return 0
    fi

    CROSS_DEPS_PREFIX="${TERMUX_PKG_CACHEDIR}/../deps"; export CROSS_DEPS_PREFIX
    local log_dir="${CROSS_DEPS_PREFIX}/build-logs"
    local deps_build="${TERMUX_PKG_CACHEDIR}/../deps-build"
    mkdir -p "${CROSS_DEPS_PREFIX}" "${log_dir}" "${deps_build}"

    local _cc="${CC:-clang}" _ar="${AR:-llvm-ar}" _ranlib="${RANLIB:-llvm-ranlib}"
    local _cf="${CFLAGS:-}" _lf="${LDFLAGS:-}"

    # bzip2
    local bz2="${deps_build}/bzip2-${_BZIP2_VERSION}"
    if [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libbz2.a" ]]; then
        _info "Building bzip2 ${_BZIP2_VERSION} ..."
        _dl_extract "https://sourceware.org/pub/bzip2/bzip2-${_BZIP2_VERSION}.tar.gz" \
            "bzip2-${_BZIP2_VERSION}.tar.gz" "$bz2"
        make -C "$bz2" -j"${TERMUX_PKG_MAKE_PROCESSES}" \
            CC="${_cc}" AR="${_ar}" RANLIB="${_ranlib}" CFLAGS="${_cf} -fPIC" \
            libbz2.a > "${log_dir}/bzip2.log" 2>&1 \
            || { cat "${log_dir}/bzip2.log" >&2; _die "bzip2 failed."; }
        install -d "${CROSS_DEPS_PREFIX}/lib" "${CROSS_DEPS_PREFIX}/include"
        install -m 644 "${bz2}/libbz2.a" "${CROSS_DEPS_PREFIX}/lib/"
        install -m 644 "${bz2}/bzlib.h"  "${CROSS_DEPS_PREFIX}/include/"
        _ok "bzip2 built."
    else _info "bzip2 already built — skipping."; fi

    # xz / liblzma
    local xz="${deps_build}/xz-${_XZ_VERSION}"
    if [[ ! -f "${CROSS_DEPS_PREFIX}/lib/liblzma.a" ]]; then
        _info "Building xz/liblzma ${_XZ_VERSION} ..."
        _dl_extract \
            "https://github.com/tukaani-project/xz/releases/download/v${_XZ_VERSION}/xz-${_XZ_VERSION}.tar.xz" \
            "xz-${_XZ_VERSION}.tar.xz" "$xz"
        ( mkdir -p "${xz}/cross-build" && cd "${xz}/cross-build"
          "${xz}/configure" --prefix="${CROSS_DEPS_PREFIX}" \
              --host="${TERMUX_HOST_PLATFORM}" --build="${TERMUX_BUILD_TUPLE}" \
              --disable-shared --enable-static \
              --disable-xz --disable-xzdec --disable-lzmadec \
              --disable-lzmainfo --disable-scripts --disable-doc \
              CC="${_cc}" CFLAGS="${_cf} -fPIC" LDFLAGS="${_lf}" \
              > "${log_dir}/xz.log" 2>&1 \
              || { cat "${log_dir}/xz.log" >&2; _die "xz configure failed."; }
          make -j"${TERMUX_PKG_MAKE_PROCESSES}" >> "${log_dir}/xz.log" 2>&1 \
              || { cat "${log_dir}/xz.log" >&2; _die "xz build failed."; }
          make install >> "${log_dir}/xz.log" 2>&1 || _die "xz install failed." )
        _ok "xz/liblzma built."
    else _info "xz/liblzma already built — skipping."; fi

    # sqlite3
    local sq="${deps_build}/sqlite-autoconf-${_SQLITE_VERSION}"
    if [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libsqlite3.a" ]]; then
        _info "Building sqlite3 ${_SQLITE_VERSION} ..."
        _dl_extract \
            "https://www.sqlite.org/${_SQLITE_YEAR}/sqlite-autoconf-${_SQLITE_VERSION}.tar.gz" \
            "sqlite-autoconf-${_SQLITE_VERSION}.tar.gz" "$sq"
        ( mkdir -p "${sq}/cross-build" && cd "${sq}/cross-build"
          "${sq}/configure" --prefix="${CROSS_DEPS_PREFIX}" \
              --host="${TERMUX_HOST_PLATFORM}" --build="${TERMUX_BUILD_TUPLE}" \
              --disable-shared --enable-static --enable-fts5 --enable-json1 \
              CC="${_cc}" CFLAGS="${_cf} -fPIC" LDFLAGS="${_lf}" \
              > "${log_dir}/sqlite.log" 2>&1 \
              || { cat "${log_dir}/sqlite.log" >&2; _die "sqlite configure failed."; }
          make -j"${TERMUX_PKG_MAKE_PROCESSES}" >> "${log_dir}/sqlite.log" 2>&1 \
              || { cat "${log_dir}/sqlite.log" >&2; _die "sqlite build failed."; }
          make install >> "${log_dir}/sqlite.log" 2>&1 || _die "sqlite install failed." )
        _ok "sqlite3 built."
    else _info "sqlite3 already built — skipping."; fi

    # OpenSSL
    local ssl="${deps_build}/openssl-${_OPENSSL_VERSION}"
    if [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libssl.a" ]]; then
        _info "Building OpenSSL ${_OPENSSL_VERSION} ..."
        _dl_extract \
            "https://github.com/openssl/openssl/releases/download/openssl-${_OPENSSL_VERSION}/openssl-${_OPENSSL_VERSION}.tar.gz" \
            "openssl-${_OPENSSL_VERSION}.tar.gz" "$ssl"
        ( cd "$ssl"
          local ossl_target
          case "${TERMUX_ARCH}" in
              aarch64) ossl_target="android-arm64"   ;;
              arm)     ossl_target="android-arm"     ;;
              x86_64)  ossl_target="android-x86_64"  ;;
              i686)    ossl_target="android-x86"     ;;
              *)       _die "Unknown arch for OpenSSL: ${TERMUX_ARCH}" ;;
          esac
          # Strip --sysroot / -target from CFLAGS: OpenSSL injects them itself
          local clean="" skip=false
          for tok in ${_cf}; do
              if $skip; then skip=false; continue; fi
              case "$tok" in -target) skip=true; continue;;
                             --sysroot=*) continue;; --sysroot) skip=true; continue;; esac
              clean+=" $tok"
          done
          export ANDROID_NDK_ROOT="${ANDROID_NDK_HOME}" CC="${_cc}"
          export CFLAGS="${clean} -fPIC" LDFLAGS="${_lf}"
          perl Configure "${ossl_target}" \
              "-D__ANDROID_API__=${TERMUX_PKG_API_LEVEL}" \
              "--prefix=${CROSS_DEPS_PREFIX}" no-shared no-tests no-ui-console \
              > "${log_dir}/openssl.log" 2>&1 \
              || { cat "${log_dir}/openssl.log" >&2; _die "OpenSSL configure failed."; }
          make -j"${TERMUX_PKG_MAKE_PROCESSES}" build_sw >> "${log_dir}/openssl.log" 2>&1 \
              || { cat "${log_dir}/openssl.log" >&2; _die "OpenSSL build failed."; }
          make install_sw >> "${log_dir}/openssl.log" 2>&1 || _die "OpenSSL install failed." )
        _ok "OpenSSL built."
    else _info "OpenSSL already built — skipping."; fi

    # libffi — from Termux .deb
    if [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libffi.so" ]] || \
       [[ ! -f "${CROSS_DEPS_PREFIX}/include/ffi.h"  ]]; then
        _info "Extracting libffi ${_LIBFFI_VERSION} ..."
        local ffi_arch="${TERMUX_HOST_PLATFORM%%-*}"
        local ffi_deb="${TERMUX_PKG_CACHEDIR}/libffi_${_LIBFFI_VERSION}_${ffi_arch}.deb"
        _download "${_LIBFFI_BASE}/libffi_${_LIBFFI_VERSION}_${ffi_arch}.deb" "$ffi_deb"
        local ffi_x="${deps_build}/libffi-deb"; rm -rf "$ffi_x"; mkdir -p "$ffi_x"
        _extract_deb "$ffi_deb" "$ffi_x"
        local ffi_usr="${ffi_x}/data/data/com.termux/files/usr"
        [[ -d "$ffi_usr" ]] || _die "libffi .deb extraction failed."
        install -d "${CROSS_DEPS_PREFIX}/include" "${CROSS_DEPS_PREFIX}/lib"
        for h in ffi.h ffitarget.h; do
            [[ -f "${ffi_usr}/include/${h}" ]] && \
                cp -a "${ffi_usr}/include/${h}" "${CROSS_DEPS_PREFIX}/include/"
        done
        local ffi_n=0
        for f in "${ffi_usr}/lib"/libffi*.so*; do
            [[ -e "$f" ]] && cp -a "$f" "${CROSS_DEPS_PREFIX}/lib/" && (( ffi_n++ )) || true
        done
        [[ "$ffi_n" -gt 0 ]] || _die "No libffi .so found."
        [[ -f "${CROSS_DEPS_PREFIX}/lib/libffi.a" ]] || \
            "${_ar}" rcs "${CROSS_DEPS_PREFIX}/lib/libffi.a" 2>/dev/null || true
        _ok "libffi extracted (${ffi_n} .so files)."
    else _info "libffi already present — skipping."; fi

    # ncurses — from Termux .deb
    if [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libncursesw.so"        ]] || \
       [[ ! -f "${CROSS_DEPS_PREFIX}/include/curses.h"          ]] || \
       [[ ! -f "${CROSS_DEPS_PREFIX}/include/ncursesw/curses.h" ]]; then
        _info "Extracting ncurses ..."
        local nc_arch="${TERMUX_HOST_PLATFORM%%-*}"
        local nc_lib="${TERMUX_PKG_CACHEDIR}/ncurses_${_NCURSES_VER_URL}_${nc_arch}.deb"
        local nc_sta="${TERMUX_PKG_CACHEDIR}/ncurses-static_${_NCURSES_VER_URL}_${nc_arch}.deb"
        _download "${_NCURSES_BASE}/ncurses/ncurses_${_NCURSES_VER_URL}_${nc_arch}.deb" "$nc_lib"
        _download "${_NCURSES_BASE}/ncurses-static/ncurses-static_${_NCURSES_VER_URL}_${nc_arch}.deb" "$nc_sta"
        local nc_x="${deps_build}/ncurses-deb"; rm -rf "$nc_x"; mkdir -p "$nc_x"
        _extract_deb "$nc_lib" "$nc_x"; _extract_deb "$nc_sta" "$nc_x"
        local nc_usr="${nc_x}/data/data/com.termux/files/usr"
        [[ -d "$nc_usr" ]] || _die "ncurses .deb extraction failed."
        install -d "${CROSS_DEPS_PREFIX}/include" "${CROSS_DEPS_PREFIX}/lib"
        [[ -d "${nc_usr}/include/ncursesw" ]] && \
            cp -a "${nc_usr}/include/ncursesw" "${CROSS_DEPS_PREFIX}/include/"
        for h in curses.h ncurses.h unctrl.h term.h termcap.h; do
            local src="${nc_usr}/include/${h}" dst="${CROSS_DEPS_PREFIX}/include/${h}"
            if [[ -f "$src" ]]; then cp -a "$src" "$dst"
            elif [[ ! -f "$dst" ]]; then
                printf '#ifndef _NCURSES_SHIM_%s\n#define _NCURSES_SHIM_%s\n#include <ncursesw/%s>\n#endif\n' \
                    "${h//./_}" "${h//./_}" "$h" > "$dst"
            fi
        done
        [[ -d "${CROSS_DEPS_PREFIX}/include/ncurses" ]] || \
            ln -sf ncursesw "${CROSS_DEPS_PREFIX}/include/ncurses" 2>/dev/null || true
        local nc_n=0
        for f in "${nc_usr}/lib"/libncurses*.so* "${nc_usr}/lib"/libpanel*.so* \
                 "${nc_usr}/lib"/libform*.so* "${nc_usr}/lib"/libmenu*.so*; do
            [[ -e "$f" ]] && cp -a "$f" "${CROSS_DEPS_PREFIX}/lib/" && (( nc_n++ )) || true
        done
        [[ "$nc_n" -gt 0 ]] || _die "No ncurses .so found."
        local nc_so; nc_so="$(ls "${CROSS_DEPS_PREFIX}/lib/libncursesw.so."* 2>/dev/null \
                              | sort -V | tail -1 || true)"
        [[ -z "$nc_so" ]] && nc_so="${CROSS_DEPS_PREFIX}/lib/libncursesw.so"
        if [[ -n "$nc_so" ]] && [[ ! -e "${CROSS_DEPS_PREFIX}/lib/libncurses.so" ]]; then
            ln -sf "$(basename "$nc_so")" "${CROSS_DEPS_PREFIX}/lib/libncurses.so" 2>/dev/null || true
        fi
        for stub in libncursesw.a libncurses.a; do
            [[ -f "${CROSS_DEPS_PREFIX}/lib/${stub}" ]] || \
                "${_ar}" rcs "${CROSS_DEPS_PREFIX}/lib/${stub}" 2>/dev/null || true
        done
        _ok "ncurses extracted (${nc_n} library files)."
    else _info "ncurses already present — skipping."; fi

    _point_build_at_deps
}

# =============================================================================
# §12  CONFIGURE
# =============================================================================
_do_configure() {
    if [[ "$_OPT_RESUME" == "true" ]]; then
        _warn "--resume: skipping configure."; return 0
    fi
    mkdir -p "$TERMUX_PKG_BUILDDIR"; cd "$TERMUX_PKG_BUILDDIR"
    _info "Running ./configure ..."
    _info "  CC:       ${CC:-<unset>}"
    _info "  CFLAGS:   ${CFLAGS:-<unset>}"
    _info "  LDFLAGS:  ${LDFLAGS:-<unset>}"
    local log="${TERMUX_PKG_LOGDIR}/configure.log"
    _info "  Log: $log"
    # shellcheck disable=SC2086
    "${TERMUX_PKG_SRCDIR}/configure" \
        --prefix="${TERMUX_PREFIX}" \
        --host="${TERMUX_HOST_PLATFORM}" \
        --build="${TERMUX_BUILD_TUPLE}" \
        --enable-shared \
        ${CONF_CACHE} \
        ${CONF_FLAGS} \
        CC="${CC:-clang}" CXX="${CXX:-clang++}" \
        AR="${AR:-llvm-ar}" RANLIB="${RANLIB:-llvm-ranlib}" \
        STRIP="${STRIP:-llvm-strip}" \
        CFLAGS="${CFLAGS}" CPPFLAGS="${CPPFLAGS}" LDFLAGS="${LDFLAGS}" \
        LIBCRYPT_LIBS="${LIBCRYPT_LIBS:-}" \
        2>&1 | tee "$log" || _die "configure failed — see: $log"
    _ok "configure finished."
}

# =============================================================================
# §13  BUILD
# =============================================================================
_do_make() {
    cd "$TERMUX_PKG_BUILDDIR"
    _info "Running make -j${TERMUX_PKG_MAKE_PROCESSES} ..."
    local log="${TERMUX_PKG_LOGDIR}/make.log"
    make -j"${TERMUX_PKG_MAKE_PROCESSES}" \
        CPPFLAGS="${CPPFLAGS}" \
        LDFLAGS="${LDFLAGS} ${PYTHON_EXTRA_LDFLAGS:-}" \
        2>&1 | tee "$log" || _die "make failed — see: $log"
    _ok "Build complete."
}

# =============================================================================
# §14  INSTALL
# =============================================================================
_do_install() {
    cd "$TERMUX_PKG_BUILDDIR"
    local log="${TERMUX_PKG_LOGDIR}/install.log"
    make install 2>&1 | tee "$log" || _die "make install failed — see: $log"
    _ok "Install complete."
}

# =============================================================================
# §15  POST-INSTALL
# =============================================================================
_post_install() {
    _info "Creating convenience symlinks ..."
    ( cd "${TERMUX_PREFIX}/bin"
      for a in python python3; do
          ln -sf "python${_MAJOR_VERSION}"        "${a}"        2>/dev/null || true
          ln -sf "python${_MAJOR_VERSION}-config" "${a}-config" 2>/dev/null || true
      done
      ln -sf "pydoc${_MAJOR_VERSION}"  pydoc  2>/dev/null || true
      ln -sf "pydoc${_MAJOR_VERSION}"  pydoc3 2>/dev/null || true
      ln -sf "idle${_MAJOR_VERSION}"   idle   2>/dev/null || true
      ln -sf "idle${_MAJOR_VERSION}"   idle3  2>/dev/null || true )
    [[ -d "${TERMUX_PREFIX}/share/man/man1" ]] && \
        ln -sf "python${_MAJOR_VERSION}.1" \
               "${TERMUX_PREFIX}/share/man/man1/python.1" 2>/dev/null || true

    # debpython helpers
    local dp_src="${TERMUX_PKG_SRCDIR}/debpython/debpython"
    if [[ -d "$dp_src" ]]; then
        local dp_dst="${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/debpython"
        install -d -m 755 "$dp_dst"
        install -m 644 "${dp_src}/"* "$dp_dst/" 2>/dev/null || true
        for prog in py3compile py3clean; do
            local ps="${TERMUX_PKG_SRCDIR}/debpython/${prog}"
            [[ -f "$ps" ]] && install -m 755 "$ps" "${TERMUX_PREFIX}/bin/"
        done
        _ok "Installed debpython helpers."
    fi

    # Byte-compile stdlib for faster startup
    _info "Byte-compiling stdlib ..."
    "${TERMUX_PREFIX}/bin/python${_MAJOR_VERSION}" -m compileall \
        -j "${TERMUX_PKG_MAKE_PROCESSES}" \
        -q "${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}" 2>/dev/null || true
    _ok "Byte-compilation complete."
}

# =============================================================================
# §16  MODULE VERIFICATION
# =============================================================================
_verify_modules() {
    if [[ "$_OPT_SKIP_VERIFY" == "true" ]]; then
        _warn "Module verification skipped."; return 0
    fi
    _info "Verifying required extension modules ..."
    local py="${TERMUX_PREFIX}/bin/python${_MAJOR_VERSION}"
    [[ -x "$py" ]] || { _warn "python${_MAJOR_VERSION} not found — skipping."; return 0; }
    local failed=0
    for mod in "${_REQUIRED_MODULES[@]}"; do
        if "$py" -c "import ${mod}" 2>/dev/null; then _ok "  Module OK: ${mod}"
        else _error "Module MISSING: ${mod}"; (( failed++ )) || true; fi
    done
    local pyrepl="${TERMUX_PREFIX}/${_PYREPL_SUBDIR}"
    if [[ -d "$pyrepl" ]] && [[ -f "${pyrepl}/__init__.py" ]]; then
        _ok "  Module OK: _pyrepl"
    else _error "Module MISSING: _pyrepl"; (( failed++ )) || true; fi
    local ver; ver="$("$py" -c 'import sys; print(sys.version)' 2>/dev/null || echo 'unknown')"
    _info "  Python version: $ver"
    [[ "$failed" -ne 0 ]] && _die "${failed} module(s) missing."
    _ok "All required modules verified."
}

# =============================================================================
# §17  STRIP + CLEANUP
# =============================================================================
_strip_and_clean() {
    if [[ "$_OPT_KEEP_TESTS" != "true" ]]; then
        _info "Removing test trees ..."
        rm -rf \
            "${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/test"     \
            "${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/"*/test   \
            "${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/"*/tests
    else _warn "Keeping test trees (--keep-tests)."; fi

    shopt -s nullglob
    local -a sp=("${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/site-packages/"*)
    shopt -u nullglob
    [[ "${#sp[@]}" -gt 0 ]] && rm -rf "${sp[@]}"

    local strip_bin="${STRIP:-llvm-strip}"
    if command -v "$strip_bin" &>/dev/null && ! _is_cross_compiling; then
        _info "Stripping .so extension modules ..."
        local n=0
        while IFS= read -r -d '' so; do
            "$strip_bin" --strip-unneeded "$so" 2>/dev/null && (( n++ )) || true
        done < <(find "${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}" -name '*.so' -print0 2>/dev/null)
        _ok "Stripped ${n} .so file(s)."
    fi
}

# =============================================================================
# §18  CREATE .deb PACKAGE
# =============================================================================
_create_deb() {
    _info "Creating .deb package ..."
    local arch; arch="$(_arch_to_deb "$TERMUX_ARCH")"
    local debname="python_${TERMUX_PKG_VERSION}-${TERMUX_PKG_REVISION}_${arch}.deb"
    local debdir="${TERMUX_PKG_BUILDDIR}/deb"
    local ctrl="${debdir}/DEBIAN"; mkdir -p "$ctrl"

    cat > "${ctrl}/control" << EOF
Package: python
Version: ${TERMUX_PKG_VERSION}-${TERMUX_PKG_REVISION}
Architecture: ${arch}
Maintainer: ${TERMUX_PKG_MAINTAINER}
Description: ${TERMUX_PKG_DESCRIPTION}
Homepage: ${TERMUX_PKG_HOMEPAGE}
Depends: gdbm, libandroid-support, libbz2, libcrypt, libffi, liblzma, libsqlite, libutil, ncurses, ncurses-ui-libs, openssl, readline, zlib
Breaks: python2
Conflicts: python2
Provides: python3
EOF

    local _CANON="data/data/com.termux/files/usr"
    local staging="${debdir}/${_CANON}"; mkdir -p "$staging"
    cp -a "${TERMUX_PREFIX}/." "$staging/"

    # Remove empty placeholder files from bin/
    local ec=0
    while IFS= read -r -d '' f; do
        _warn "  Removing empty: bin/$(basename "$f")"; rm -f "$f"; (( ec++ )) || true
    done < <(find "${staging}/bin" -maxdepth 1 -type f -empty -print0 2>/dev/null)
    [[ "$ec" -gt 0 ]] && _warn "Removed ${ec} empty file(s) from bin/."

    # postinst — canonical paths only (not CI workspace paths)
    local _p="/${_CANON}"
    {
        printf '#!/usr/bin/env bash\nset -e\n\n'
        printf '_pip_pkg() {\n'
        printf '    case "${TERMUX_PACKAGE_FORMAT:-debian}" in\n'
        printf '        debian) [[ -f "%s/var/lib/dpkg/info/python-pip.list" ]] ;;\n'       "${_p}"
        printf '        pacman) ls "%s/var/lib/pacman/local/python-pip-"* &>/dev/null ;;\n' "${_p}"
        printf '        *)      return 1 ;;\n    esac\n}\n\n'
        printf 'if [[ -f "%s/bin/pip" ]] && ! _pip_pkg; then\n'                             "${_p}"
        printf '    echo "Removing unmanaged pip..."\n'
        printf '    rm -f "%s/bin/pip" "%s/bin/pip3"* "%s/bin/easy_install"*\n'            "${_p}" "${_p}" "${_p}"
        printf '    rm -rf "%s/lib/python%s/site-packages/pip"*\n'                         "${_p}" "${_MAJOR_VERSION}"
        printf '    rm -rf "%s/lib/python%s/site-packages/setuptools"*\n'                  "${_p}" "${_MAJOR_VERSION}"
        printf 'fi\n'
        printf '[[ -f "%s/bin/pip" ]] || echo "NOTE: install pip with: pkg install python-pip"\n\n' "${_p}"
        printf 'for _old in 3.11 3.12 3.13; do\n'
        printf '    [[ -d "%s/lib/python${_old}/site-packages" ]] || continue\n'           "${_p}"
        printf '    echo "NOTE: Python updated to %s. Reinstall pip packages."\n'           "${_MAJOR_VERSION}"
        printf '    break\ndone\nexit 0\n'
    } > "${ctrl}/postinst"
    chmod 0755 "${ctrl}/postinst"
    bash -n "${ctrl}/postinst" || _die "postinst has syntax errors."

    mkdir -p "$OUTPUT_DIR"
    local out="${OUTPUT_DIR}/${debname}"

    if command -v dpkg-deb &>/dev/null; then
        dpkg-deb --build "$debdir" "$out" || _die "dpkg-deb failed."
    else
        _warn "dpkg-deb not available — building manually ..."
        local tmp; tmp="$(mktemp -d)"
        echo "2.0" > "${tmp}/debian-binary"
        tar -czf "${tmp}/control.tar.gz" -C "$ctrl" . \
            || { rm -rf "$tmp"; _die "control.tar.gz failed."; }
        tar -cf  "${tmp}/data.tar" --exclude='./DEBIAN' -C "$debdir" . \
            || { rm -rf "$tmp"; _die "data.tar failed."; }
        xz -z -T0 "${tmp}/data.tar" \
            || { rm -rf "$tmp"; _die "xz compression failed."; }
        local _ar="ar"; command -v gar &>/dev/null && _ar="gar"
        "${_ar}" -rcs "$out" \
            "${tmp}/debian-binary" "${tmp}/control.tar.gz" "${tmp}/data.tar.xz" \
            || { rm -rf "$tmp"; _die "ar assembly failed."; }
        rm -rf "$tmp"
    fi

    local size; size="$(du -sh "$out" | cut -f1)"
    local sha;  sha="$(_sha256 "$out")"
    _ok "Package: $(basename "$out")  (${size})"
    _info "  SHA256: $sha"
    printf '%s  %s\n' "$sha" "$(basename "$out")" > "${out}.sha256"
    _ok "Wrote: $(basename "$out").sha256"
    echo "$out"
}

# =============================================================================
# §19  SUMMARY REPORT
# =============================================================================
_print_summary() {
    local debfile="${1:-}"
    local elapsed=$(( SECONDS - _START_SECONDS ))
    local mins=$(( elapsed / 60 )) secs=$(( elapsed % 60 ))
    _section "build-pkg.sh — Done"
    printf "  %-24s %s\n" "Python:"         "${TERMUX_PKG_VERSION}-${TERMUX_PKG_REVISION}"
    printf "  %-24s %s\n" "Arch:"           "${TERMUX_ARCH}  (${TERMUX_HOST_PLATFORM})"
    printf "  %-24s %s\n" "API level:"      "${TERMUX_PKG_API_LEVEL}"
    printf "  %-24s %s\n" "Prefix:"         "${TERMUX_PREFIX}"
    printf "  %-24s %s\n" "Free-threaded:"  "${_OPT_FREE_THREADED}"
    printf "  %-24s %s\n" "Elapsed:"        "${mins}m ${secs}s"
    [[ -n "$debfile" ]] && {
        printf "\n  %-24s %s\n" ".deb:" "$debfile"
        printf   "  %-24s %s\n" "SHA256:" "${debfile}.sha256"
    }
    echo
}

# =============================================================================
# §20  MAIN
# =============================================================================
main() {
    _START_SECONDS=$SECONDS
    _parse_args "$@"
    _setup_env

    _section "Termux Python ${TERMUX_PKG_VERSION} — Build for Android"
    printf "  %-24s %s\n" "Version:"        "${TERMUX_PKG_VERSION} (rev ${TERMUX_PKG_REVISION})"
    printf "  %-24s %s\n" "API Level:"      "${TERMUX_PKG_API_LEVEL}"
    printf "  %-24s %s\n" "Arch:"           "${TERMUX_ARCH}"
    printf "  %-24s %s\n" "Host triple:"    "${TERMUX_HOST_PLATFORM}"
    printf "  %-24s %s\n" "Build triple:"   "${TERMUX_BUILD_TUPLE}"
    printf "  %-24s %s\n" "Prefix:"         "${TERMUX_PREFIX}"
    printf "  %-24s %s\n" "On-device:"      "${TERMUX_ON_DEVICE_BUILD}"
    printf "  %-24s %s\n" "Make jobs:"      "${TERMUX_PKG_MAKE_PROCESSES}"
    printf "  %-24s %s\n" "Free-threaded:"  "${_OPT_FREE_THREADED}"
    printf "  %-24s %s\n" "No-deb:"         "${_OPT_NO_DEB}"
    printf "  %-24s %s\n" "No-deps:"        "${_OPT_NO_DEPS}"
    printf "  %-24s %s\n" "Resume:"         "${_OPT_RESUME}"
    printf "  %-24s %s\n" "Keep-tests:"     "${_OPT_KEEP_TESTS}"
    printf "  %-24s %s\n" "Skip-verify:"    "${_OPT_SKIP_VERIFY}"
    printf "  %-24s %s\n" "Source URL:"     "${PATCHED_SOURCE_URL}"
    echo

    _section "Step  1/12 — Tool Check";            _check_tools

    if [[ "$_OPT_CLEAN" == "true" ]]; then
        _section "Step  2/12 — Clean"
        rm -rf "$TERMUX_PKG_SRCDIR" "$TERMUX_PKG_BUILDDIR"; _ok "Cleaned."
    else _info "Step  2/12 — Clean skipped (pass --clean to wipe build dirs)."; fi
    mkdir -p "$TERMUX_PKG_CACHEDIR" "$TERMUX_PKG_LOGDIR"

    _section "Step  3/12 — Download Patched Source"
    _download "${PATCHED_SOURCE_URL}" "${TERMUX_PKG_CACHEDIR}/${_PATCHED_TARBALL}"
    # Verify against companion .sha256 if present
    local sha256_c="${TERMUX_PKG_CACHEDIR}/${_PATCHED_TARBALL}.sha256"
    if [[ -f "$sha256_c" ]]; then
        local exp; exp="$(awk '{print $1}' "$sha256_c")"
        local got; got="$(_sha256 "${TERMUX_PKG_CACHEDIR}/${_PATCHED_TARBALL}")"
        [[ "$got" == "$exp" ]] && _ok "Companion .sha256 verified." \
            || _die "SHA256 mismatch on patched source tarball."
    fi

    if [[ "$_OPT_RESUME" != "true" ]]; then
        _section "Step  4/12 — Unpack Patched Source"
        rm -rf "$TERMUX_PKG_SRCDIR"; mkdir -p "$TERMUX_PKG_SRCDIR"
        tar -xJf "${TERMUX_PKG_CACHEDIR}/${_PATCHED_TARBALL}" \
            --strip-components=1 -C "$TERMUX_PKG_SRCDIR" \
            || _die "Failed to unpack patched source tarball."
        _ok "Source unpacked  ($(find "$TERMUX_PKG_SRCDIR" -type f | wc -l | tr -d ' ') files)."
    else _info "Step  4/12 — Unpack skipped (--resume)."; fi

    _section "Step  5/12 — Setup Compiler Flags";  _setup_flags
    _section "Step  6/12 — Cross-Compile Dependencies"; _build_deps
    _section "Step  7/12 — Configure";             _do_configure
    _section "Step  8/12 — Build";                 _do_make
    _section "Step  9/12 — Install";               _do_install
    _section "Step 10/12 — Post-Install";          _post_install
    _section "Step 11/12 — Strip + Clean";         _strip_and_clean
    _section "Step 11b/12 — Module Verification";  _verify_modules

    _section "Step 12/12 — Package"
    local debfile=""
    if [[ "$_OPT_NO_DEB" == "true" ]]; then
        _warn "--no-deb set — skipping packaging."
    else
        debfile="$(_create_deb)"
    fi

    _print_summary "$debfile"
}

_START_SECONDS=$SECONDS
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
