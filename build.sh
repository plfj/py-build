#!/usr/bin/env bash
# =============================================================================
# Termux Python 3.14.3 — build.sh
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
#   PATCHED_SOURCE_URL=https://example.com/python-3.14.3-patched-src.tar.xz \
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
readonly TERMUX_PKG_LICENSE="PythonPL"
readonly TERMUX_PKG_MAINTAINER="@termux"
readonly TERMUX_PKG_VERSION="3.14.3"
readonly TERMUX_PKG_REVISION=0
readonly _MAJOR_VERSION="${TERMUX_PKG_VERSION%.*}"   # -> "3.14"

# Name of the patched-source tarball (must match prepare-source.sh)
readonly _PATCHED_TARBALL="python-${TERMUX_PKG_VERSION}-patched-src.tar.xz"

# Required extension modules that must survive post-install.
# Python 3.14 notes:
#   - _crypt was removed in 3.13; not listed.
#   - _pyrepl is pure Python (Lib/_pyrepl/); verified by directory presence.
#   - _interpchannels and _interpqueues are new in 3.14 (interpreter isolation).
#   - _testcapi and _testinternalcapi are build-only; not listed.
readonly -a _REQUIRED_MODULES=(_bz2 _ctypes _curses _lzma _sqlite3 _ssl zlib
                                _interpchannels _interpqueues)
readonly _PYREPL_SUBDIR="lib/python${_MAJOR_VERSION}/_pyrepl"

# =============================================================================
# §2  OPTION FLAGS  (only boolean flags remain; everything else is env-driven)
# =============================================================================
_OPT_CLEAN=false
_OPT_SKIP_VERIFY=false
_OPT_NO_DEB=false
_OPT_KEEP_TESTS=false

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
    elif command -v sysctl &>/dev/null && sysctl -n hw.ncpu &>/dev/null 2>&1; then
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
# Returns true if the build host cannot execute the target binaries directly.
_is_cross_compiling() {
    [[ "$TERMUX_ON_DEVICE_BUILD" != "true" ]]
}

# =============================================================================
# §8  ENVIRONMENT DETECTION + DEFAULTS
# =============================================================================
_setup_env() {
    # ── Prefix ────────────────────────────────────────────────────────────────
    if [[ -z "${TERMUX_PREFIX:-}" ]]; then
        export TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
    fi

    # ── API level ─────────────────────────────────────────────────────────────
    if [[ -z "${TERMUX_PKG_API_LEVEL:-}" ]]; then export TERMUX_PKG_API_LEVEL=35; fi

    # ── Arch ──────────────────────────────────────────────────────────────────
    if [[ -z "${TERMUX_ARCH:-}" ]]; then TERMUX_ARCH="$(uname -m)"; export TERMUX_ARCH; fi
    TERMUX_ARCH="$(_normalize_arch "$TERMUX_ARCH")"
    export TERMUX_ARCH

    # ── Toolchain + package format ────────────────────────────────────────────
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

    # ── Parallel jobs ─────────────────────────────────────────────────────────
    _detect_cpu_count
    if [[ -z "${TERMUX_PKG_MAKE_PROCESSES:-}" ]]; then
        TERMUX_PKG_MAKE_PROCESSES="${CPU_COUNT}"
        export TERMUX_PKG_MAKE_PROCESSES
    fi

    # ── Auto-skip module verification when cross-compiling ────────────────────
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
    # GitHub Actions injects when a ${{ }} expression resolves to empty string.
    PATCHED_SOURCE_URL="${PATCHED_SOURCE_URL:-}"
    PATCHED_SOURCE_URL="${PATCHED_SOURCE_URL#__}"
    PATCHED_SOURCE_URL="${PATCHED_SOURCE_URL%__}"
    PATCHED_SOURCE_URL="${PATCHED_SOURCE_URL// /}"
    export PATCHED_SOURCE_URL

    if [[ -z "$PATCHED_SOURCE_URL" ]]; then
        _die "PATCHED_SOURCE_URL is not set. Check that prepare-source exposes release_tag as a job output."
    fi
    if [[ "$PATCHED_SOURCE_URL" != http://* && "$PATCHED_SOURCE_URL" != https://* ]]; then
        _die "PATCHED_SOURCE_URL does not look like a URL: '${PATCHED_SOURCE_URL}'."
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
}

_download() {
    local url="$1" dest="$2" expected="${3:-}"
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
}

# =============================================================================
# §10  TOOL CHECK
# =============================================================================
_check_tools() {
    _info "Checking required build tools ..."
    local -a required=(make tar pkg-config perl gawk ar zstd)
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
    if [[ "$missing" -ne 0 ]]; then
        _die "${missing} required tool(s) missing — install them and retry."
    fi
    _ok "All required tools present."
}

# =============================================================================
# §11  PRE-CONFIGURE FLAGS
# =============================================================================
_setup_flags() {
    unset PKG_CONFIG_PATH CPPFLAGS_HOST LDFLAGS_HOST

    # Python 3.14 requires a host python3 for the freeze / bootstrap step.
    # Prefer python3.14 if already installed (e.g. a previous build), then
    # fall back to any python3.
    local _BUILD_PYTHON
    _BUILD_PYTHON="$(command -v "python${_MAJOR_VERSION}" \
                   || command -v python3 \
                   || { _warn "No host Python found — configure may fail."; \
                        echo "python${_MAJOR_VERSION}"; })"
    _info "Host Python (--with-build-python): $_BUILD_PYTHON"

    # ── CFLAGS ────────────────────────────────────────────────────────────────
    CFLAGS="${CFLAGS:-}"
    CFLAGS="${CFLAGS/-Oz/-O3}"                        # -Oz breaks Python on Android
    if [[ ! "$CFLAGS" =~ -O[0-9s] ]]; then CFLAGS+=" -O3"; fi
    CFLAGS+=" -fno-semantic-interposition"             # improves call-through-plt perf

    # Python 3.14: LTO is enabled by --with-lto in configure (see build.sh
    # TERMUX_PKG_EXTRA_CONFIGURE_ARGS). Explicit -flto here would duplicate it
    # and may cause CFLAGS/configure disagreements. Leave LTO to configure.

    if [[ -n "${SYSROOT:-}" ]] && [[ "$CFLAGS" != *--sysroot* ]]; then
        CFLAGS+=" --sysroot=${SYSROOT}"
    fi
    if [[ -n "${ANDROID_BUILD_TARGET:-}" ]] && [[ "$CFLAGS" != *-target* ]]; then
        CFLAGS+=" -target ${ANDROID_BUILD_TARGET}"
    fi

    # ── LDFLAGS ───────────────────────────────────────────────────────────────
    LDFLAGS="${LDFLAGS:-}"
    LDFLAGS="${LDFLAGS//-Wl,--as-needed/}"             # breaks extension module linking
    if [[ -n "${SYSROOT:-}" ]] && [[ "$LDFLAGS" != *--sysroot* ]]; then
        LDFLAGS+=" --sysroot=${SYSROOT}"
    fi
    if [[ "$LDFLAGS" != *-fuse-ld* ]]; then
        LDFLAGS+=" -fuse-ld=lld"
    fi

    # ── CPPFLAGS + sysroot include / lib ─────────────────────────────────────
    CPPFLAGS="${CPPFLAGS:-}"
    local _sysroot="${TERMUX_STANDALONE_TOOLCHAIN}/sysroot"
    local _sysroot_inc="${_sysroot}/usr/include"
    local _sysroot_lib_base="${_sysroot}/usr/lib"
    local _sysroot_lib_arch="${_sysroot_lib_base}/${TERMUX_HOST_PLATFORM}"
    local _sysroot_lib_api="${_sysroot_lib_arch}/${TERMUX_PKG_API_LEVEL}"
    if [[ -d "${_sysroot_inc}" ]]; then
        CPPFLAGS+=" -I${_sysroot_inc}"
        if [[ -d "${_sysroot_inc}/${TERMUX_HOST_PLATFORM}" ]]; then
            CPPFLAGS+=" -I${_sysroot_inc}/${TERMUX_HOST_PLATFORM}"
        fi
    fi
    for _ldir in "$_sysroot_lib_api" "$_sysroot_lib_arch" "$_sysroot_lib_base"; do
        [[ -d "$_ldir" ]] && LDFLAGS+=" -L${_ldir}"
    done

    # ── On-device: explicit API level define ──────────────────────────────────
    if [[ "$TERMUX_ON_DEVICE_BUILD" == "true" ]]; then
        local sdk_ver
        sdk_ver="$(getprop ro.build.version.sdk 2>/dev/null || echo "${TERMUX_PKG_API_LEVEL}")"
        CPPFLAGS+=" -D__ANDROID_API__=${sdk_ver}"
    fi

    # ── autoconf cache vars ───────────────────────────────────────────────────
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
    # Python 3.14: sem_open / sem_unlink are unblocked (patch 0005 removes the
    # configure.ac block). Set the cache vars to 'yes' to match.
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
    # Python 3.14: new configure probes for interpreter isolation features
    CONF_CACHE+=" ac_cv_func_pthread_getname_np=yes"
    CONF_CACHE+=" ac_cv_func_pthread_setname_np=yes"
    # Python 3.14: free-threaded build (PEP 703) — disable by default
    CONF_CACHE+=" ac_cv_with_disable_gil=no"

    # ── configure feature flags ───────────────────────────────────────────────
    CONF_FLAGS="${CONF_FLAGS:-}"
    CONF_FLAGS+=" --with-build-python=${_BUILD_PYTHON}"
    CONF_FLAGS+=" --with-system-ffi"
    # Python 3.14: --without-static-libpython avoids linking libpython.a into
    # the interpreter — required for extension module dlopen to work on Android.
    CONF_FLAGS+=" --without-static-libpython"
    # Python 3.14: --with-lto enables link-time optimisation via the configure
    # mechanism rather than raw -flto, so the compiler and linker flags stay
    # consistent with Python's own feature-detection.
    CONF_FLAGS+=" --with-lto"
    CONF_FLAGS+=" --without-ensurepip"
    CONF_FLAGS+=" --enable-loadable-sqlite-extensions"
    # Python 3.14: official Android cross-compilation flag (see patch 0012).
    CONF_FLAGS+=" --with-android-api-level=${TERMUX_PKG_API_LEVEL}"

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
    # At API >= 30 bionic provides named semaphores natively (and patch 0005
    # unblocks sem_open/sem_unlink in configure.ac for all API levels, relying
    # on the shm_open emulation in posixshmem.c on older APIs).
    # libandroid-spawn: posix_spawn polyfill for API < 28.
    PYTHON_EXTRA_LDFLAGS=""
    if (( TERMUX_PKG_API_LEVEL < 30 )); then
        if [[ -f "${TERMUX_PREFIX}/lib/libandroid-posix-semaphore.a" ]] || \
           [[ -f "${TERMUX_PREFIX}/lib/libandroid-posix-semaphore.so" ]]; then
            PYTHON_EXTRA_LDFLAGS+=" -landroid-posix-semaphore"
            LDFLAGS+=" -L${TERMUX_PREFIX}/lib"
        else
            _warn "libandroid-posix-semaphore not found — skipping (API ${TERMUX_PKG_API_LEVEL})"
        fi
    fi
    if (( TERMUX_PKG_API_LEVEL < 28 )); then
        if [[ -f "${TERMUX_PREFIX}/lib/libandroid-spawn.a" ]] || \
           [[ -f "${TERMUX_PREFIX}/lib/libandroid-spawn.so" ]]; then
            PYTHON_EXTRA_LDFLAGS+=" -landroid-spawn"
        else
            _warn "libandroid-spawn not found — skipping (API ${TERMUX_PKG_API_LEVEL})"
        fi
    fi
    export PYTHON_EXTRA_LDFLAGS

    # Python 3.14: distutils is fully removed. LIBCRYPT_LIBS is still needed
    # for third-party packages that invoke python3-config --libs.
    if [[ "$TERMUX_ON_DEVICE_BUILD" == "true" ]] || \
       [[ -f "${TERMUX_PREFIX}/lib/libcrypt.a"  ]] || \
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
# Builds bzip2, xz, sqlite3, and openssl from source against the NDK sysroot.
# ncurses and libffi are extracted from Termux .deb packages — cross-compiling
# either from source requires a two-phase build that is not viable here.
# On an on-device build all packages are already installed; we reuse them.
#
# Dependency versions — bump when upstream ships a security release.
_BZIP2_VERSION="1.0.8"
_XZ_VERSION="5.6.3"
_SQLITE_VERSION="3490100"   # 3.49.1 (YYYYMMDD0 autoconf tarball naming)
_OPENSSL_VERSION="3.4.1"
_LIBFFI_VERSION="3.4.7-1"
_LIBFFI_TERMUX_BASE_URL="https://packages.termux.dev/apt/termux-main/pool/main/libf/libffi"
_NCURSES_TERMUX_VERSION="6.6.20260124+really6.5.20250830"
_NCURSES_TERMUX_VERSION_URL="6.6.20260124%2Breally6.5.20250830"
_NCURSES_TERMUX_BASE_URL="https://packages.termux.dev/apt/termux-main/pool/main/n"

_build_deps() {
    if [[ "$TERMUX_ON_DEVICE_BUILD" == "true" ]]; then
        _info "On-device build — using TERMUX_PREFIX libraries for dependencies."
        CROSS_DEPS_PREFIX="${TERMUX_PREFIX}"
        export CROSS_DEPS_PREFIX
        return 0
    fi

    CROSS_DEPS_PREFIX="${TMPDIR:-/tmp}/python-build/deps"
    export CROSS_DEPS_PREFIX
    local log_dir="${CROSS_DEPS_PREFIX}/build-logs"
    local deps_build="${TMPDIR:-/tmp}/python-build/deps-build"
    mkdir -p "${CROSS_DEPS_PREFIX}" "${log_dir}" "${deps_build}" "${TERMUX_PKG_CACHEDIR}"

    local _cc="${CC:-clang}"
    local _cxx="${CXX:-clang++}"
    local _ar="${AR:-llvm-ar}"
    local _ranlib="${RANLIB:-llvm-ranlib}"
    local _cflags="${CFLAGS:-}"
    local _ldflags="${LDFLAGS:-}"

    # ── helper: download + extract ────────────────────────────────────────────
    _dl_extract() {
        local url="$1" tarball="$2" dir="$3"
        _download "$url" "${TERMUX_PKG_CACHEDIR}/${tarball}"
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
            make install >> "${log_dir}/xz-configure.log" 2>&1 || _die "xz install failed."
        )
        _ok "xz/liblzma built."
    else
        _info "xz/liblzma already built — skipping."
    fi

    # ── sqlite3 ───────────────────────────────────────────────────────────────
    # SQLite URL year directory: 2025 for 3.49.x
    local _sqlite_year="2025"
    local sq_src="${deps_build}/sqlite-autoconf-${_SQLITE_VERSION}"
    if [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libsqlite3.a" ]]; then
        _info "Building sqlite3 ${_SQLITE_VERSION} ..."
        _dl_extract \
            "https://www.sqlite.org/${_sqlite_year}/sqlite-autoconf-${_SQLITE_VERSION}.tar.gz" \
            "sqlite-autoconf-${_SQLITE_VERSION}.tar.gz" \
            "$sq_src"
        (
            mkdir -p "${sq_src}/cross-build"
            cd "${sq_src}/cross-build"
            "${sq_src}/configure" \
                --prefix="${CROSS_DEPS_PREFIX}" \
                --host="${TERMUX_HOST_PLATFORM}" \
                --build="${TERMUX_BUILD_TUPLE}" \
                --disable-shared --enable-static \
                --enable-fts5 --enable-json1 \
                CC="${_cc}" CFLAGS="${_cflags} -fPIC" LDFLAGS="${_ldflags}" \
                > "${log_dir}/sqlite.log" 2>&1 \
                || { cat "${log_dir}/sqlite.log"; _die "sqlite configure failed."; }
            make -j"${TERMUX_PKG_MAKE_PROCESSES}" \
                >> "${log_dir}/sqlite.log" 2>&1 \
                || { cat "${log_dir}/sqlite.log"; _die "sqlite build failed."; }
            make install >> "${log_dir}/sqlite.log" 2>&1 || _die "sqlite install failed."
        )
        _ok "sqlite3 built."
    else
        _info "sqlite3 already built — skipping."
    fi

    # ── openssl ───────────────────────────────────────────────────────────────
    local ssl_src="${deps_build}/openssl-${_OPENSSL_VERSION}"
    if [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libssl.a" ]]; then
        _info "Building OpenSSL ${_OPENSSL_VERSION} ..."
        _dl_extract \
            "https://github.com/openssl/openssl/releases/download/openssl-${_OPENSSL_VERSION}/openssl-${_OPENSSL_VERSION}.tar.gz" \
            "openssl-${_OPENSSL_VERSION}.tar.gz" \
            "$ssl_src"
        (
            cd "$ssl_src"
            local ossl_target
            case "${TERMUX_ARCH}" in
                aarch64) ossl_target="android-arm64"  ;;
                arm)     ossl_target="android-arm"    ;;
                x86_64)  ossl_target="android-x86_64" ;;
                i686)    ossl_target="android-x86"    ;;
                *)       _die "Unknown arch for OpenSSL: ${TERMUX_ARCH}" ;;
            esac

            # Strip --sysroot and -target from CFLAGS: OpenSSL's android-*
            # platform target injects both from ANDROID_NDK_ROOT itself.
            local ossl_cflags_clean="" _skip_next=false
            for _tok in ${_cflags}; do
                if [[ "$_skip_next" == "true" ]]; then _skip_next=false; continue; fi
                if [[ "$_tok" == "-target"    ]]; then _skip_next=true; continue; fi
                if [[ "$_tok" == --sysroot=* ]]; then continue; fi
                if [[ "$_tok" == "--sysroot"  ]]; then _skip_next=true; continue; fi
                ossl_cflags_clean="${ossl_cflags_clean} ${_tok}"
            done

            export ANDROID_NDK_ROOT="${ANDROID_NDK_HOME}"
            export CC="${_cc}"
            export CFLAGS="${ossl_cflags_clean} -fPIC"
            export LDFLAGS="${_ldflags}"

            perl Configure "${ossl_target}" \
                "-D__ANDROID_API__=${TERMUX_PKG_API_LEVEL}" \
                "--prefix=${CROSS_DEPS_PREFIX}" \
                no-shared no-tests no-ui-console \
                > "${log_dir}/openssl.log" 2>&1 \
                || { cat "${log_dir}/openssl.log"; _die "openssl configure failed."; }
            make -j"${TERMUX_PKG_MAKE_PROCESSES}" build_sw \
                >> "${log_dir}/openssl.log" 2>&1 \
                || { cat "${log_dir}/openssl.log"; _die "openssl build failed."; }
            make install_sw >> "${log_dir}/openssl.log" 2>&1 || _die "openssl install failed."
        )
        _ok "OpenSSL built."
    else
        _info "OpenSSL already built — skipping."
    fi

    # ── libffi — extracted from Termux .deb ───────────────────────────────────
    # Required for _ctypes (Python 3.14 still uses libffi for ctypes).
    if [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libffi.so"  ]] || \
       [[ ! -f "${CROSS_DEPS_PREFIX}/include/ffi.h"  ]]; then
        _info "Extracting libffi ${_LIBFFI_VERSION} from Termux .deb ..."
        local _ffi_arch="${TERMUX_HOST_PLATFORM%%-*}"
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
            local data_tar; data_tar="$(ls data.tar.* 2>/dev/null | head -1)"
            [[ -n "$data_tar" ]] || _die "No data.tar.* in libffi.deb"
            case "$data_tar" in
                *.xz)  tar -xJf "$data_tar" -C "$ffi_extract" ;;
                *.gz)  tar -xzf "$data_tar" -C "$ffi_extract" ;;
                *.zst) zstd -d  "$data_tar" --stdout | tar -x -C "$ffi_extract" ;;
                *)     _die "Unknown format: $data_tar" ;;
            esac
        )

        local ffi_usr="${ffi_extract}/data/data/com.termux/files/usr"
        [[ -d "$ffi_usr" ]] || _die "libffi .deb extraction failed."
        install -d "${CROSS_DEPS_PREFIX}/include" "${CROSS_DEPS_PREFIX}/lib"
        for _hdr in ffi.h ffitarget.h; do
            [[ -f "${ffi_usr}/include/${_hdr}" ]] && \
                cp -a "${ffi_usr}/include/${_hdr}" "${CROSS_DEPS_PREFIX}/include/"
        done
        local _ffi_found=0
        for f in "${ffi_usr}/lib"/libffi*.so*; do
            [[ -e "$f" ]] && cp -a "$f" "${CROSS_DEPS_PREFIX}/lib/" && (( _ffi_found++ )) || true
        done
        [[ "$_ffi_found" -gt 0 ]] || _die "No libffi .so files found in extracted .deb"
        [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libffi.a" ]] && \
            "${AR:-llvm-ar}" rcs "${CROSS_DEPS_PREFIX}/lib/libffi.a" 2>/dev/null || true
        _ok "libffi extracted (${_ffi_found} .so files)."
    else
        _info "libffi already present — skipping."
    fi

    # ── ncurses — extracted from Termux .deb ──────────────────────────────────
    if [[ ! -f "${CROSS_DEPS_PREFIX}/lib/libncursesw.so"        ]] || \
       [[ ! -f "${CROSS_DEPS_PREFIX}/include/curses.h"          ]] || \
       [[ ! -f "${CROSS_DEPS_PREFIX}/include/ncursesw/curses.h" ]]; then
        _info "Extracting ncurses from Termux .deb ..."
        local _nc_arch="${TERMUX_HOST_PLATFORM%%-*}"
        local nc_lib_deb="${TERMUX_PKG_CACHEDIR}/ncurses.deb"
        local nc_static_deb="${TERMUX_PKG_CACHEDIR}/ncurses-static.deb"
        _download \
            "${_NCURSES_TERMUX_BASE_URL}/ncurses/ncurses_${_NCURSES_TERMUX_VERSION_URL}_${_nc_arch}.deb" \
            "$nc_lib_deb"
        _download \
            "${_NCURSES_TERMUX_BASE_URL}/ncurses-static/ncurses-static_${_NCURSES_TERMUX_VERSION_URL}_${_nc_arch}.deb" \
            "$nc_static_deb"

        local nc_extract="${deps_build}/ncurses-deb"
        rm -rf "$nc_extract"; mkdir -p "$nc_extract"

        for deb in "$nc_lib_deb" "$nc_static_deb"; do
            local deb_tmp="${nc_extract}/tmp_$(basename "$deb")"
            mkdir -p "$deb_tmp"
            (
                cd "$deb_tmp"
                ar x "$deb"
                local data_tar; data_tar="$(ls data.tar.* 2>/dev/null | head -1)"
                [[ -n "$data_tar" ]] || _die "No data.tar.* in $(basename "$deb")"
                case "$data_tar" in
                    *.xz)  tar -xJf "$data_tar" -C "$nc_extract" ;;
                    *.gz)  tar -xzf "$data_tar" -C "$nc_extract" ;;
                    *.zst) zstd -d  "$data_tar" --stdout | tar -x -C "$nc_extract" ;;
                    *)     _die "Unknown data archive format: $data_tar" ;;
                esac
            )
        done

        local termux_usr="${nc_extract}/data/data/com.termux/files/usr"
        [[ -d "$termux_usr" ]] || _die "ncurses .deb extraction failed."
        install -d "${CROSS_DEPS_PREFIX}/include" "${CROSS_DEPS_PREFIX}/lib"

        # Headers: canonical ncursesw/ subdir + flat shims
        if [[ -d "${termux_usr}/include/ncursesw" ]]; then
            cp -a "${termux_usr}/include/ncursesw" "${CROSS_DEPS_PREFIX}/include/"
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
        [[ ! -d "${CROSS_DEPS_PREFIX}/include/ncurses" ]] && \
            ln -sf ncursesw "${CROSS_DEPS_PREFIX}/include/ncurses" 2>/dev/null || true

        # Shared libraries
        local _nc_found=0
        for f in "${termux_usr}/lib"/libncurses*.so* \
                 "${termux_usr}/lib"/libpanel*.so*   \
                 "${termux_usr}/lib"/libform*.so*    \
                 "${termux_usr}/lib"/libmenu*.so*; do
            [[ -e "$f" ]] && cp -a "$f" "${CROSS_DEPS_PREFIX}/lib/" && (( _nc_found++ )) || true
        done
        [[ "$_nc_found" -gt 0 ]] || _die "No ncurses .so files found in extracted .deb"

        # libncurses.so alias for configure probes using -lncurses
        local _nc_so; _nc_so="$(ls "${CROSS_DEPS_PREFIX}/lib/libncursesw.so."* 2>/dev/null | head -1 || true)"
        [[ -z "$_nc_so" ]] && _nc_so="${CROSS_DEPS_PREFIX}/lib/libncursesw.so"
        if [[ -n "$_nc_so" ]] && [[ ! -e "${CROSS_DEPS_PREFIX}/lib/libncurses.so" ]]; then
            ln -sf "$(basename "$_nc_so")" "${CROSS_DEPS_PREFIX}/lib/libncurses.so" 2>/dev/null || true
        fi

        # Stub .a sentinels for configure probes
        for stub in libncursesw.a libncurses.a; do
            [[ ! -f "${CROSS_DEPS_PREFIX}/lib/${stub}" ]] && \
                "${AR:-llvm-ar}" rcs "${CROSS_DEPS_PREFIX}/lib/${stub}" 2>/dev/null || true
        done
        _ok "ncurses extracted (${_nc_found} files)."
    else
        _info "ncurses already present — skipping."
    fi

    # ── Point Python build at the cross-built deps ────────────────────────────
    CPPFLAGS+=" -I${CROSS_DEPS_PREFIX}/include"
    LDFLAGS+=" -L${CROSS_DEPS_PREFIX}/lib"
    export PKG_CONFIG_PATH="${CROSS_DEPS_PREFIX}/lib/pkgconfig"
    export PKG_CONFIG_LIBDIR="${CROSS_DEPS_PREFIX}/lib/pkgconfig"
    export CPPFLAGS LDFLAGS

    CONF_FLAGS+=" CURSES_CFLAGS=-I${CROSS_DEPS_PREFIX}/include/ncursesw"
    CONF_FLAGS+=" CURSES_LIBS=-lncursesw"
    CONF_FLAGS+=" PANEL_LIBS=-lpanelw"
    export CONF_FLAGS
    _ok "All cross-compiled dependencies ready at ${CROSS_DEPS_PREFIX}."
}

# =============================================================================
# §12  CONFIGURE
# =============================================================================
_do_configure() {
    mkdir -p "$TERMUX_PKG_BUILDDIR"
    cd "$TERMUX_PKG_BUILDDIR"
    _info "Running ./configure ..."
    _info "  CC:      ${CC:-<unset>}"
    _info "  CXX:     ${CXX:-<unset>}"
    _info "  CFLAGS:  ${CFLAGS:-<unset>}"
    _info "  LDFLAGS: ${LDFLAGS:-<unset>}"

    # shellcheck disable=SC2086
    "${TERMUX_PKG_SRCDIR}/configure" \
        --prefix="${TERMUX_PREFIX}"        \
        --host="${TERMUX_HOST_PLATFORM}"   \
        --build="${TERMUX_BUILD_TUPLE}"    \
        --enable-shared                    \
        ${CONF_CACHE}                      \
        ${CONF_FLAGS}                      \
        CC="${CC:-clang}"                  \
        CXX="${CXX:-clang++}"              \
        AR="${AR:-llvm-ar}"                \
        RANLIB="${RANLIB:-llvm-ranlib}"    \
        STRIP="${STRIP:-llvm-strip}"       \
        CFLAGS="${CFLAGS}"                 \
        CPPFLAGS="${CPPFLAGS}"             \
        LDFLAGS="${LDFLAGS}"               \
        LIBCRYPT_LIBS="${LIBCRYPT_LIBS:-}" \
        2>&1 | tee configure.log \
        || _die "configure failed — see: ${TERMUX_PKG_BUILDDIR}/configure.log"
    _ok "configure finished."
}

# =============================================================================
# §13  POST-INSTALL
# =============================================================================
_post_install() {
    _info "Creating convenience symlinks ..."
    (
        cd "${TERMUX_PREFIX}/bin"
        # Python 3.14 installs python3.14, idle3.14, pydoc3.14, python3.14-config.
        # Provide unversioned and python3-versioned aliases.
        for _alias in python python3; do
            ln -sf "python${_MAJOR_VERSION}"        "${_alias}"        2>/dev/null || true
            ln -sf "python${_MAJOR_VERSION}-config" "${_alias}-config" 2>/dev/null || true
        done
        ln -sf "pydoc${_MAJOR_VERSION}"  pydoc  2>/dev/null || true
        ln -sf "pydoc${_MAJOR_VERSION}"  pydoc3 2>/dev/null || true
        ln -sf "idle${_MAJOR_VERSION}"   idle   2>/dev/null || true
        ln -sf "idle${_MAJOR_VERSION}"   idle3  2>/dev/null || true
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
            [[ -f "$prog_src" ]] && install -m 755 "$prog_src" "${TERMUX_PREFIX}/bin/"
        done
        _ok "Installed debpython helpers."
    fi
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
    # _pyrepl: pure Python — check directory presence
    local pyrepl_dir="${TERMUX_PREFIX}/${_PYREPL_SUBDIR}"
    if [[ -d "$pyrepl_dir" ]] && [[ -f "${pyrepl_dir}/__init__.py" ]]; then
        _ok "  Module OK: _pyrepl (${pyrepl_dir})"
    else
        _error "Module missing: _pyrepl — expected at ${pyrepl_dir}"
        (( failed++ )) || true
    fi
    if [[ "$failed" -ne 0 ]]; then _die "${failed} required module(s) missing."; fi
    _ok "All required modules present."
}

# =============================================================================
# §14b  PATCH _pyrepl FOR ANDROID COMPATIBILITY
# =============================================================================
# Python 3.14 status for known _pyrepl issues:
#
# 1. gh-135621 (_curses imported unconditionally in unix_console.py) — FIXED
#    upstream in 3.14 before release. No patch needed here.
#
# 2. gh-134466 (termios.tcsetattr crash in degraded terminal) — FIXED in 3.13.12
#    and also present in 3.14. No patch needed.
#
# 3. Android _pyrepl degraded-mode fallback: if TERM is unset or the terminal
#    does not support tput, _pyrepl should gracefully fall back to the simple
#    REPL rather than printing a traceback. Python 3.14 includes the upstream
#    fix for this (bpo-84872). Verify at runtime; patch only if the fix is absent.
#
# This function is intentionally a no-op for Python 3.14 but is retained as
# a hook for any regressions discovered after release.
_patch_pyrepl() {
    local unix_console="${TERMUX_PKG_SRCDIR}/Lib/_pyrepl/unix_console.py"

    if [[ ! -f "$unix_console" ]]; then
        _warn "_patch_pyrepl: ${unix_console} not found — skipping."
        return 0
    fi

    # Python 3.14 already guards _curses imports — verify and report.
    if grep -q 'except ImportError' "$unix_console"; then
        _ok "_pyrepl/unix_console.py: _curses ImportError guard already present (upstream fix in 3.14)."
    else
        # Upstream fix is absent — this should not happen with an unmodified 3.14.3
        # source tree, but apply the guard defensively.
        _warn "_pyrepl/unix_console.py: _curses ImportError guard missing — applying fallback patch."
        sed -i.bak \
            's|^import _curses$|try:\n    import _curses\nexcept ImportError:\n    _curses = None  # Android fallback|' \
            "$unix_console" \
            && _ok "_pyrepl/unix_console.py: guard applied." \
            || _warn "_pyrepl/unix_console.py: sed patch failed."
        rm -f "${unix_console}.bak" 2>/dev/null || true
    fi

    _ok "_pyrepl check complete."
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
Maintainer: ${TERMUX_PKG_MAINTAINER}
Description: ${TERMUX_PKG_DESCRIPTION}
Homepage: ${TERMUX_PKG_HOMEPAGE}
Depends: gdbm, libandroid-support, libbz2, libcrypt, libffi, liblzma, libsqlite, libutil, ncurses, ncurses-ui-libs, openssl, readline, zlib
Breaks: python2
Conflicts: python2
Provides: python3
EOF

    local _TERMUX_CANONICAL="data/data/com.termux/files/usr"
    local staging="${debdir}/${_TERMUX_CANONICAL}"
    mkdir -p "$staging"
    cp -a "${TERMUX_PREFIX}/." "$staging/"

    # Remove empty placeholder files from bin/
    local _empty_count=0
    while IFS= read -r -d '' _f; do
        _warn "  Removing empty file from bin/: $(basename "$_f")"
        rm -f "$_f"
        (( _empty_count++ )) || true
    done < <(find "${staging}/bin" -maxdepth 1 -type f -empty -print0 2>/dev/null)
    [[ "$_empty_count" -gt 0 ]] && \
        _warn "Removed ${_empty_count} empty file(s) from bin/." || \
        _info "bin/ is clean — no empty files."

    # postinst — runs on device; must use canonical Termux prefix, not CI path
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
        # Python 3.14: pip is a separate package (python-pip).
        # Remove any unmanaged pip left over from a manual `pip install --upgrade pip`.
        printf 'if [[ -f "%s/bin/pip" ]] && ! _pip_managed_by_pkg; then\n'                 "${_p}"
        printf '    echo "Removing unmanaged pip..."\n'
        printf '    rm -f "%s/bin/pip" "%s/bin/pip3"* "%s/bin/easy_install"*\n'            "${_p}" "${_p}" "${_p}"
        printf '    rm -rf "%s/lib/python%s/site-packages/pip"*\n'                         "${_p}" "${_MAJOR_VERSION}"
        printf 'fi\n\n'
        printf 'if [[ ! -f "%s/bin/pip" ]]; then\n'                                        "${_p}"
        printf '    echo "== Note: pip is now a separate package: pkg install python-pip =="\n'
        printf 'fi\n\n'
        # Warn if stale site-packages from an older Python version are present.
        printf 'for _old_ver in 3.11 3.12 3.13; do\n'
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
        echo "2.0" > "${tmp}/debian-binary"
        tar -czf "${tmp}/control.tar.gz" -C "$ctrl" . \
            || { rm -rf "$tmp"; _die "control.tar.gz creation failed."; }
        tar -cf "${tmp}/data.tar" --exclude='./DEBIAN' -C "$debdir" . \
            || { rm -rf "$tmp"; _die "data.tar creation failed."; }
        xz -z -T0 "${tmp}/data.tar" \
            || { rm -rf "$tmp"; _die "xz compression of data.tar failed."; }
        local _ar="ar"
        command -v gar &>/dev/null && _ar="gar"
        "${_ar}" -rcs "$debout" \
            "${tmp}/debian-binary" \
            "${tmp}/control.tar.gz" \
            "${tmp}/data.tar.xz" \
            || { rm -rf "$tmp"; _die "ar failed assembling .deb."; }
        rm -rf "$tmp"
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
    printf "  %-20s %s\n" "No-deb:"       "${_OPT_NO_DEB}"
    printf "  %-20s %s\n" "Keep-tests:"   "${_OPT_KEEP_TESTS}"
    printf "  %-20s %s\n" "Skip-verify:"  "${_OPT_SKIP_VERIFY}"
    printf "  %-20s %s\n" "Source URL:"   "${PATCHED_SOURCE_URL}"
    echo

    _section "Step 1/11 — Tool Check"
    _check_tools

    if [[ "$_OPT_CLEAN" == "true" ]]; then
        _section "Step 2/11 — Clean"
        rm -rf "$TERMUX_PKG_SRCDIR" "$TERMUX_PKG_BUILDDIR"
        _ok "Clean complete."
    else
        _info "Step 2/11 — Clean skipped (pass --clean to wipe build dirs)."
    fi

    _section "Step 3/11 — Download Patched Source"
    mkdir -p "$TERMUX_PKG_CACHEDIR" "$TERMUX_PKG_SRCDIR"
    _download "${PATCHED_SOURCE_URL}" "${TERMUX_PKG_CACHEDIR}/${_PATCHED_TARBALL}"

    _section "Step 4/11 — Unpack Patched Source"
    _info "Unpacking ${_PATCHED_TARBALL} ..."
    rm -rf "$TERMUX_PKG_SRCDIR"
    mkdir -p "$TERMUX_PKG_SRCDIR"
    tar -xJf "${TERMUX_PKG_CACHEDIR}/${_PATCHED_TARBALL}" \
        --strip-components=1 -C "$TERMUX_PKG_SRCDIR" \
        || _die "Failed to unpack patched source tarball."
    _ok "Patched source unpacked."

    _section "Step 4b/11 — Check _pyrepl for Android compatibility"
    _patch_pyrepl

    _section "Step 5/11 — Setup Compiler Flags"
    _setup_flags

    _section "Step 6/11 — Cross-Compile Dependencies"
    _build_deps

    _section "Step 7/11 — Configure"
    _do_configure

    _section "Step 8/11 — Build"
    _info "make -j${TERMUX_PKG_MAKE_PROCESSES} ..."
    cd "$TERMUX_PKG_BUILDDIR"
    make -j"${TERMUX_PKG_MAKE_PROCESSES}" \
        CPPFLAGS="${CPPFLAGS}" \
        LDFLAGS="${LDFLAGS} ${PYTHON_EXTRA_LDFLAGS:-}" \
        || _die "make failed."
    _ok "Build complete."

    _section "Step 9/11 — Install"
    make install || _die "make install failed."
    _ok "Install complete."

    _section "Step 10/11 — Post-Install + Module Verification"
    _post_install
    _verify_modules

    _section "Step 11/11 — Package"
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

    local debfile
    debfile="$(_create_deb)"

    _section "Build Successful"
    printf "  Python %s installed to : %s\n"   "${TERMUX_PKG_VERSION}" "${TERMUX_PREFIX}"
    printf "  .deb package           : %s\n\n" "${debfile}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
