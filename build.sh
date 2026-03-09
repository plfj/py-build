#!/usr/bin/env bash
# =============================================================================
# Termux Python 3.13.12 — build.sh
# =============================================================================
# Usage:
#   bash build.sh [OPTIONS]
#
#   Options:
#     --help          Show this help message and exit
#     --clean         Wipe build/src dirs before starting
#     --skip-verify   Skip post-install module verification
#     --jobs N        Override parallel make job count (default: nproc)
#
# Patch files must be present in a patches/ directory alongside this script.
# Obtain them from:
#   https://github.com/termux/termux-packages/tree/master/packages/python
#
# Supports both:
#   (a) On-device Termux build  (bash build.sh directly in Termux)
#   (b) termux build-package.sh (TERMUX_PKG_* variables already exported)
#
# Sources:
#   [A] termux/termux-packages  packages/python/build.sh  v3.13.12 REVISION=3
#   [B] yubrajbhoi/termux-python @ 3b0139c                v3.13.6
#   [C] termux/termux-packages  build-package.sh           pipeline reference
#
# Bionic API reference:
#   https://android.googlesource.com/platform/bionic/+/master/docs/status.md
# =============================================================================
set -euo pipefail

# =============================================================================
# §0  SCRIPT IDENTITY
# =============================================================================
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly _SCRIPT_DIR
readonly _PATCH_DIR="${_SCRIPT_DIR}/patches"

# =============================================================================
# §1  PACKAGE CONSTANTS
# =============================================================================
readonly TERMUX_PKG_HOMEPAGE="https://python.org/"
readonly TERMUX_PKG_DESCRIPTION="Python 3 programming language intended to enable clear programs"
readonly TERMUX_PKG_LICENSE="custom"
readonly TERMUX_PKG_LICENSE_FILE="LICENSE"
readonly TERMUX_PKG_MAINTAINER="Yaksh Bariya <thunder-coding@termux.dev>"
readonly TERMUX_PKG_VERSION="3.13.12"
readonly TERMUX_PKG_REVISION=3
readonly _MAJOR_VERSION="${TERMUX_PKG_VERSION%.*}"   # -> "3.13"

# Debian python3-defaults commit
readonly _DEBPYTHON_COMMIT="f358ab52bf2932ad55b1a72a29c9762169e6ac47"

# =============================================================================
# §2  SOURCE URLs + SHA256
# =============================================================================
readonly _PYTHON_URL="https://www.python.org/ftp/python/${TERMUX_PKG_VERSION}/Python-${TERMUX_PKG_VERSION}.tgz"
readonly _PYTHON_SHA256="12e7cb170ad2d1a69aee96a1cc7fc8de5b1e97a2bdac51683a3db016ec9a2996"

readonly _DEBPYTHON_URL="https://salsa.debian.org/cpython-team/python3-defaults/-/archive/${_DEBPYTHON_COMMIT}/python3-defaults-${_DEBPYTHON_COMMIT}.tar.gz"
readonly _DEBPYTHON_SHA256="3b7a76c144d39f5c4a2c7789fd4beb3266980c2e667ad36167e1e7a357c684b0"

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

# Critical extension modules that must be present after install.
readonly -a _REQUIRED_MODULES=(_bz2 _curses _lzma _sqlite3 _ssl _tkinter zlib)

# =============================================================================
# §4  OPTION VARIABLES (mutated by _parse_args)
# =============================================================================
_OPT_CLEAN=false
_OPT_SKIP_VERIFY=false
_OPT_JOBS=""

# =============================================================================
# §5  LOGGING HELPERS
# =============================================================================
# Emit ANSI colour codes only when stderr is a real terminal.
if [[ -t 2 ]]; then
    _C_RST='\033[0m'
    _C_BLU='\033[1;34m'
    _C_GRN='\033[1;32m'
    _C_YLW='\033[1;33m'
    _C_RED='\033[1;31m'
    _C_CYN='\033[1;36m'
else
    _C_RST='' _C_BLU='' _C_GRN='' _C_YLW='' _C_RED='' _C_CYN=''
fi

_info()    { printf "${_C_BLU}[INFO]${_C_RST}   %s\n"  "$*";       }
_ok()      { printf "${_C_GRN}[ OK ]${_C_RST}   %s\n"  "$*";       }
_warn()    { printf "${_C_YLW}[WARN]${_C_RST}   %s\n"  "$*" >&2;   }
_error()   { printf "${_C_RED}[ERR ]${_C_RST}   %s\n"  "$*" >&2;   }
_die()     { _error "$*"; exit 1;                                    }

_section() {
    local line="══════════════════════════════════════════════════════════════"
    printf "\n${_C_CYN}%s\n  %s\n%s${_C_RST}\n\n" "$line" "$*" "$line"
}

# =============================================================================
# §6  ARGUMENT PARSING
# =============================================================================
_usage() {
    # Print the usage block from the header comment.
    sed -n '/^# Usage:/,/^# Patch/p' "$0" | sed 's/^# \{0,2\}//'
    exit 0
}

_parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --help|-h)
                _usage
                ;;
            --clean)
                _OPT_CLEAN=true
                ;;
            --skip-verify)
                _OPT_SKIP_VERIFY=true
                ;;
            --jobs|-j)
                [[ -n "${2:-}" ]] || _die "--jobs requires a numeric argument"
                [[ "$2" =~ ^[1-9][0-9]*$ ]] || \
                    _die "--jobs must be a positive integer, got: $2"
                _OPT_JOBS="$2"
                shift
                ;;
            *)
                _die "Unknown option: '$1'  (try --help)"
                ;;
        esac
        shift
    done
}

# =============================================================================
# §7  ARCH -> TRIPLET HELPER
# =============================================================================
_arch_to_triplet() {
    case "$1" in
        aarch64) echo "aarch64-linux-android" ;;
        arm)     echo "arm-linux-androideabi"  ;;
        i686)    echo "i686-linux-android"     ;;
        x86_64)  echo "x86_64-linux-android"   ;;
        *)       echo "$1-linux-android"        ;;
    esac
}

# =============================================================================
# §8  ENVIRONMENT DETECTION + DEFAULTS
# =============================================================================
_setup_env() {
    # Prefer values already exported by build-package.sh; fill defaults only
    # when running standalone.

    if [[ -z "${TERMUX_PREFIX:-}" ]]; then
        export TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
    fi
    if [[ -z "${TERMUX_PKG_SRCDIR:-}" ]]; then
        export TERMUX_PKG_SRCDIR="${TMPDIR:-/tmp}/python-build/src"
    fi
    if [[ -z "${TERMUX_PKG_BUILDDIR:-}" ]]; then
        export TERMUX_PKG_BUILDDIR="${TMPDIR:-/tmp}/python-build/build"
    fi
    if [[ -z "${TERMUX_PKG_CACHEDIR:-}" ]]; then
        export TERMUX_PKG_CACHEDIR="${TMPDIR:-/tmp}/python-build/cache"
    fi

    # Android API level: auto-detect on device, default 24 (Termux minimum).
    if [[ -z "${TERMUX_PKG_API_LEVEL:-}" ]]; then
        if command -v getprop &>/dev/null; then
            TERMUX_PKG_API_LEVEL="$(getprop ro.build.version.sdk 2>/dev/null || echo 24)"
        else
            TERMUX_PKG_API_LEVEL=24
        fi
        export TERMUX_PKG_API_LEVEL
    fi

    # Normalise arch names to Termux conventions (armv7l/armv8l -> arm).
    if [[ -z "${TERMUX_ARCH:-}" ]]; then
        TERMUX_ARCH="$(uname -m | sed 's/armv[78]l/arm/')"
        export TERMUX_ARCH
    fi

    # On-device detection: Android marker files or uname output.
    if [[ -z "${TERMUX_ON_DEVICE_BUILD:-}" ]]; then
        if [[ "$(uname -o 2>/dev/null)" == "Android" ]] || \
           [[ -e "/system/bin/app_process" ]]; then
            export TERMUX_ON_DEVICE_BUILD=true
        else
            export TERMUX_ON_DEVICE_BUILD=false
        fi
    fi

    if [[ -z "${TERMUX_STANDALONE_TOOLCHAIN:-}" ]]; then
        export TERMUX_STANDALONE_TOOLCHAIN="${TERMUX_PREFIX}"
    fi
    if [[ -z "${TERMUX_PACKAGE_FORMAT:-}" ]]; then
        export TERMUX_PACKAGE_FORMAT="debian"
    fi

    # Resolve cross-compile triplets.
    if [[ -z "${TERMUX_HOST_PLATFORM:-}" ]]; then
        TERMUX_HOST_PLATFORM="$(_arch_to_triplet "$TERMUX_ARCH")"
        export TERMUX_HOST_PLATFORM
    fi
    if [[ -z "${TERMUX_BUILD_TUPLE:-}" ]]; then
        if [[ "$TERMUX_ON_DEVICE_BUILD" == "true" ]]; then
            TERMUX_BUILD_TUPLE="$(_arch_to_triplet "$TERMUX_ARCH")"
        else
            TERMUX_BUILD_TUPLE="$(uname -m)-linux-gnu"
        fi
        export TERMUX_BUILD_TUPLE
    fi

    # Parallel job count: CLI flag > existing env var > nproc/sysctl.
    if [[ -n "${_OPT_JOBS}" ]]; then
        export TERMUX_PKG_MAKE_PROCESSES="${_OPT_JOBS}"
    elif [[ -z "${TERMUX_PKG_MAKE_PROCESSES:-}" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            TERMUX_PKG_MAKE_PROCESSES="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
        else
            TERMUX_PKG_MAKE_PROCESSES="$(nproc 2>/dev/null || echo 1)"
        fi
        export TERMUX_PKG_MAKE_PROCESSES
    fi
}

# =============================================================================
# §9  DOWNLOAD + VERIFY HELPERS
# =============================================================================
_sha256() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        _die "No SHA-256 utility found (tried sha256sum, shasum). Install one and retry."
    fi
}

_download() {
    local url="$1" dest="$2" expected_sha256="$3"
    mkdir -p "$(dirname "$dest")"

    # Use cached file if SHA256 still matches.
    if [[ -f "$dest" ]]; then
        local actual
        actual="$(_sha256 "$dest")"
        if [[ "$actual" == "$expected_sha256" ]]; then
            _ok "Cache hit: $(basename "$dest")"
            return 0
        fi
        _warn "SHA256 mismatch on cached file — re-downloading: $(basename "$dest")"
        rm -f "$dest"
    fi

    _info "Downloading: $url"
    local tmpfile="${dest}.tmp.$$"
    # Ensure tmpfile is cleaned up even if this function is interrupted.
    trap 'rm -f "$tmpfile"' RETURN INT TERM

    if command -v curl &>/dev/null; then
        curl -fL --retry 5 --retry-delay 2 --connect-timeout 30 \
             --progress-bar -o "$tmpfile" "$url" \
            || _die "curl failed to download: $url"
    elif command -v wget &>/dev/null; then
        wget --tries=5 --timeout=30 -q --show-progress \
             -O "$tmpfile" "$url" \
            || _die "wget failed to download: $url"
    else
        _die "Neither curl nor wget found. Install one and retry."
    fi

    local actual
    actual="$(_sha256 "$tmpfile")"
    if [[ "$actual" != "$expected_sha256" ]]; then
        rm -f "$tmpfile"
        _error "SHA256 mismatch for $(basename "$dest")"
        _error "  Expected : $expected_sha256"
        _error "  Got      : $actual"
        _die   "Download integrity check failed."
    fi

    mv "$tmpfile" "$dest"
    _ok "Downloaded: $(basename "$dest")"
}

# =============================================================================
# §10  PRE-BUILD TOOL CHECK
# =============================================================================
_check_tools() {
    _info "Checking required build tools ..."
    local -a required=(make patch tar pkg-config)
    local missing=0

    # autoreconf is strongly recommended; warn if absent rather than aborting.
    command -v autoreconf &>/dev/null || \
        _warn "autoreconf not found; configure regeneration will be skipped."

    # Need at least one C compiler.
    if ! command -v clang &>/dev/null && ! command -v gcc &>/dev/null; then
        required+=(clang)
    fi
    # Need at least one downloader.
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        required+=(curl)
    fi
    # Need a SHA-256 utility.
    if ! command -v sha256sum &>/dev/null && ! command -v shasum &>/dev/null; then
        required+=(sha256sum)
    fi

    for tool in "${required[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            _error "Required tool not found: $tool"
            (( missing++ )) || true
        fi
    done

    if (( missing > 0 )); then
        _die "${missing} required tool(s) missing. Install them and retry."
    fi
    _ok "All required tools present."
}

# =============================================================================
# §11  PATCH VALIDATION
# =============================================================================
_validate_patches() {
    _info "Validating patch files in: $_PATCH_DIR"
    local missing=0
    for f in "${_PATCH_FILES[@]}"; do
        local p="${_PATCH_DIR}/${f}"
        if [[ ! -f "$p" ]]; then
            _error "Missing patch file : patches/${f}"
            (( missing++ )) || true
        elif [[ ! -s "$p" ]]; then
            _error "Empty patch file   : patches/${f}"
            (( missing++ )) || true
        fi
    done
    if (( missing > 0 )); then
        _error "${missing} patch file(s) missing or empty."
        _error "Obtain patches from:"
        _error "  https://github.com/termux/termux-packages/tree/master/packages/python"
        exit 1
    fi
    _ok "All ${#_PATCH_FILES[@]} patch files present."
}

# =============================================================================
# §12  termux_step_post_get_source
# =============================================================================
# Applies the API-level-templated 0012 patch via sed (must precede the generic
# loop) and renames the python3-defaults directory to the stable "debpython" path.
# =============================================================================
termux_step_post_get_source() {
    local patch="${_PATCH_DIR}/0012-hardcode-android-api-level.diff"

    _info "Applying 0012-hardcode-android-api-level.diff (API=${TERMUX_PKG_API_LEVEL})"
    [[ -f "$patch" ]] || _die "Template patch not found: $patch"

    sed -e "s%@TERMUX_PKG_API_LEVEL@%${TERMUX_PKG_API_LEVEL}%g" "$patch" \
        | patch --silent -p1 \
        || _die "Failed to apply 0012-hardcode-android-api-level.diff"
    _ok "Applied: 0012-hardcode-android-api-level.diff"

    # Rename unpacked python3-defaults to the stable path used by later hooks.
    local debpython_unpacked="${TERMUX_PKG_SRCDIR}/python3-defaults-${_DEBPYTHON_COMMIT}"
    if [[ -d "$debpython_unpacked" ]]; then
        mv "$debpython_unpacked" "${TERMUX_PKG_SRCDIR}/debpython"
        _ok "Renamed python3-defaults -> debpython"
    elif [[ ! -d "${TERMUX_PKG_SRCDIR}/debpython" ]]; then
        _die "debpython directory not found after unpack."
    fi
}

# =============================================================================
# §13  _apply_patches
# =============================================================================
# Applies all patches EXCEPT 0012, which was already applied with sed
# substitution in termux_step_post_get_source.  Applying 0012 twice would
# silently corrupt the source tree or cause a hard failure.
# =============================================================================
_apply_patches() {
    _info "Applying patches from: $_PATCH_DIR  (0012 already applied)"

    # Collect all .patch and .diff files then sort lexicographically.
    local -a patch_files=()
    for _p in "${_PATCH_DIR}"/*.patch "${_PATCH_DIR}"/*.diff; do
        [[ -f "$_p" ]] && patch_files+=("$_p")
    done

    (( ${#patch_files[@]} > 0 )) || _die "No patch files found in: $_PATCH_DIR"

    IFS=$'\n' read -r -d '' -a patch_files \
        < <(printf '%s\n' "${patch_files[@]}" | sort && printf '\0') || true

    local applied=0 skipped=0
    for patch_path in "${patch_files[@]}"; do
        local patch_name
        patch_name="$(basename "$patch_path")"

        # Skip 0012 — already applied with template substitution.
        if [[ "$patch_name" == *"hardcode-android-api-level"* ]]; then
            _info "Skipping (pre-applied): $patch_name"
            (( skipped++ )) || true
            continue
        fi

        _info "Applying: $patch_name"
        patch -p1 --silent < "$patch_path" \
            || _die "Failed to apply patch: $patch_name"
        (( applied++ )) || true
    done

    _ok "Patches applied: ${applied}  (skipped: ${skipped})"
}

# =============================================================================
# §14  termux_step_pre_configure
# =============================================================================
# Sets compiler/linker flags, API-level-gated configure cache vars, and runs
# autoreconf to regenerate the configure script after patching configure.ac.
# =============================================================================
termux_step_pre_configure() {
    cd "$TERMUX_PKG_SRCDIR"

    # -- §14.1  Build-host Python ------------------------------------------
    if command -v termux_setup_build_python &>/dev/null; then
        termux_setup_build_python
    fi
    local _BUILD_PYTHON
    _BUILD_PYTHON="$(command -v "python${_MAJOR_VERSION}" \
                   || command -v python3 \
                   || { _warn "No host Python found; configure may fail."; \
                        echo "python${_MAJOR_VERSION}"; })"
    _info "Host Python: $_BUILD_PYTHON"

    # -- §14.2  Compiler flags ---------------------------------------------
    # Replace -Oz with -O3 for throughput; append if no -O flag is present.
    CFLAGS="${CFLAGS:-}"
    CFLAGS="${CFLAGS/-Oz/-O3}"
    [[ "$CFLAGS" =~ -O[0-9s] ]] || CFLAGS+=" -O3"
    # -fno-semantic-interposition: permits inlining across TUs (~5-8% speedup).
    CFLAGS+=" -fno-semantic-interposition"

    CPPFLAGS="${CPPFLAGS:-}"
    CPPFLAGS+=" -I${TERMUX_STANDALONE_TOOLCHAIN}/sysroot/usr/include"

    # -- §14.3  Linker flags -----------------------------------------------
    # Strip --as-needed: it removes libpython3.so symbols, breaking embedding
    # and any extension module that links against the shared library.
    LDFLAGS="${LDFLAGS:-}"
    LDFLAGS="${LDFLAGS//-Wl,--as-needed/}"
    LDFLAGS+=" -L${TERMUX_STANDALONE_TOOLCHAIN}/sysroot/usr/lib"
    # x86_64 sysroot requires a "64" suffix on the lib path.
    [[ "$TERMUX_ARCH" == "x86_64" ]] && LDFLAGS+="64"

    # On-device: inject __ANDROID_API__ which configure probes via cpp.
    if [[ "$TERMUX_ON_DEVICE_BUILD" == "true" ]]; then
        local sdk_ver
        sdk_ver="$(getprop ro.build.version.sdk 2>/dev/null \
                   || echo "${TERMUX_PKG_API_LEVEL}")"
        CPPFLAGS+=" -D__ANDROID_API__=${sdk_ver}"
    fi

    # -- §14.4  Static configure cache vars (all API levels) ---------------
    CONF="${CONF:-}"
    CONF+=" ac_cv_file__dev_ptmx=yes"
    CONF+=" ac_cv_file__dev_ptc=no"
    CONF+=" ac_cv_func_wcsftime=no"           # wide strftime crash on Android
    CONF+=" ac_cv_func_ftime=no"              # <sys/timeb.h> absent since API 21
    CONF+=" ac_cv_func_faccessat=no"          # AT_EACCESS not defined in Bionic
    CONF+=" ac_cv_func_linkat=no"             # linkat(2) absent on Android 6
    CONF+=" ac_cv_buggy_getaddrinfo=no"       # cross-compile: assume not buggy
    CONF+=" ac_cv_little_endian_double=yes"   # cross-compile: fix endian probe
    CONF+=" ac_cv_posix_semaphores_enabled=yes"
    CONF+=" ac_cv_func_sem_open=yes"
    CONF+=" ac_cv_func_sem_timedwait=yes"
    CONF+=" ac_cv_func_sem_getvalue=yes"
    CONF+=" ac_cv_func_sem_unlink=yes"
    CONF+=" ac_cv_func_shm_open=yes"         # libandroid-support / Bionic 26+
    CONF+=" ac_cv_func_shm_unlink=yes"
    CONF+=" ac_cv_working_tzset=yes"
    CONF+=" ac_cv_header_sys_xattr_h=no"     # xattr blocked by SELinux in Termux
    CONF+=" ac_cv_func_getgrent=yes"         # Termux grp.h has inline stub
    CONF+=" ac_cv_func_posix_spawn=yes"      # libandroid-spawn / Bionic 28+
    CONF+=" ac_cv_func_posix_spawnp=yes"
    CONF+=" --build=${TERMUX_BUILD_TUPLE}"
    CONF+=" --with-build-python=${_BUILD_PYTHON}"
    CONF+=" --with-system-ffi"
    CONF+=" --with-system-expat"
    CONF+=" --without-ensurepip"
    CONF+=" --enable-loadable-sqlite-extensions"

    # -- §14.5  API-level-gated configure overrides ------------------------
    # Source: Android Bionic status.md (confirmed March 2026)
    #   https://android.googlesource.com/platform/bionic/+/master/docs/status.md

    # API 28 (Android 9 / Pie)
    # fexecve:    subprocess exec-without-fork path in Python 3.13
    # getlogin_r: getpass / login module functionality
    if (( TERMUX_PKG_API_LEVEL < 28 )); then
        CONF+=" ac_cv_func_fexecve=no"
        CONF+=" ac_cv_func_getlogin_r=no"
    fi

    # API 29 (Android 10)
    # getloadavg: os.getloadavg()
    if (( TERMUX_PKG_API_LEVEL < 29 )); then
        CONF+=" ac_cv_func_getloadavg=no"
    fi

    # API 30 (Android 11)
    # sem_clockwait: _multiprocessing C extension
    # memfd_create:  multiprocessing.shared_memory
    if (( TERMUX_PKG_API_LEVEL < 30 )); then
        CONF+=" ac_cv_func_sem_clockwait=no"
        CONF+=" ac_cv_func_memfd_create=no"
    fi

    # API 31 (Android 12)
    # pidfd_getfd:     multiprocessing resource reducer (Python 3.12+)
    # process_madvise: not used by CPython core; gated for forward-compat
    if (( TERMUX_PKG_API_LEVEL < 31 )); then
        CONF+=" ac_cv_func_pidfd_getfd=no"
        CONF+=" ac_cv_func_process_madvise=no"
    fi

    # API 33 (Android 13)
    # preadv2/pwritev2: os.preadv/os.pwritev with RWF_* flag support
    if (( TERMUX_PKG_API_LEVEL < 33 )); then
        CONF+=" ac_cv_func_preadv2=no"
        CONF+=" ac_cv_func_pwritev2=no"
    fi

    # API 34 (Android 14)
    # ★ close_range — CRITICAL for Python 3.13.
    #   Python/fileutils.c calls close_range() unconditionally in 3.13.
    #   Without this gate: "error: call to undeclared function 'close_range'"
    # copy_file_range:  shutil.copy2() fast-path
    # addchdir_np:      subprocess child CWD setting via posix_spawn
    if (( TERMUX_PKG_API_LEVEL < 34 )); then
        CONF+=" ac_cv_func_close_range=no"
        CONF+=" ac_cv_func_copy_file_range=no"
        CONF+=" ac_cv_func_posix_spawn_file_actions_addchdir_np=no"
        CONF+=" ac_cv_func_posix_spawn_file_actions_addfchdir_np=no"
    fi

    # API 35 (Android 15)
    # epoll_pwait2:             not yet used by CPython 3.13; gated for future
    # tcgetwinsize/tcsetwinsize: POSIX.1-2024 terminal size; tty/pty modules
    if (( TERMUX_PKG_API_LEVEL < 35 )); then
        CONF+=" ac_cv_func_epoll_pwait2=no"
        CONF+=" ac_cv_func_tcgetwinsize=no"
        CONF+=" ac_cv_func_tcsetwinsize=no"
    fi

    # API 36 (Android 16)
    # qsort_r:              some C extensions probe at configure time
    # pthread_*affinity_np: not used by CPython 3.13 core
    if (( TERMUX_PKG_API_LEVEL < 36 )); then
        CONF+=" ac_cv_func_qsort_r=no"
        CONF+=" ac_cv_func_pthread_getaffinity_np=no"
        CONF+=" ac_cv_func_pthread_setaffinity_np=no"
    fi

    # -- §14.6  Polyfill libraries ------------------------------------------
    LDFLAGS+=" -landroid-posix-semaphore"  # POSIX semaphore shim [A]
    LDFLAGS+=" -landroid-spawn"            # posix_spawn polyfill for API<28 [B]
    export LIBCRYPT_LIBS="-lcrypt"         # explicit crypt for crypt/hashlib [A]

    export CFLAGS CPPFLAGS LDFLAGS CONF

    # -- §14.7  debpython version-placeholder substitution -----------------
    local debpython_dir="${TERMUX_PKG_SRCDIR}/debpython"
    if [[ -d "$debpython_dir" ]]; then
        local fullver="${TERMUX_PKG_VERSION}-${TERMUX_PKG_REVISION}"
        local count=0
        while IFS= read -r -d '' file; do
            sed -i.bak \
                -e "s|@TERMUX_PYTHON_VERSION@|${_MAJOR_VERSION}|g" \
                -e "s|@TERMUX_PKG_FULLVERSION@|${fullver}|g" \
                "$file"
            (( count++ )) || true
        done < <(find "$debpython_dir" -type f -print0)
        _ok "debpython: substituted version placeholders in ${count} file(s)."
    else
        _warn "debpython directory not found — skipping placeholder substitution."
    fi

    # -- §14.8  Regenerate autotools configure -----------------------------
    # Must run after patches have been applied to configure.ac.
    cd "$TERMUX_PKG_SRCDIR"
    ./configure \
      --host=aarch64-linux-android \
      --build=x86_64-apple-darwin \
      --with-build-python=$(which python3.13) \
      --without-ensurepip \
      --enable-shared \
      --disable-ipv6 \
      ac_cv_file__dev_ptmx=yes \
      ac_cv_file__dev_ptc=no
    make regen-all
    make regen-configure
    if command -v autoreconf &>/dev/null; then
        _info "Running autoreconf -ivf -Werror ..."
        autoreconf -ivf -Werror
        _ok "autoreconf complete."
    else
        _warn "autoreconf not found — skipping regeneration."
        _warn "If ./configure fails, install autoconf and automake."
    fi
}

# =============================================================================
# §15  _do_configure
# =============================================================================
_do_configure() {
    mkdir -p "$TERMUX_PKG_BUILDDIR"
    cd "$TERMUX_PKG_BUILDDIR"

    _info "Running ./configure ..."
    # shellcheck disable=SC2086
    "${TERMUX_PKG_SRCDIR}/configure" \
        --prefix="${TERMUX_PREFIX}" \
        --host="${TERMUX_HOST_PLATFORM}" \
        --build="${TERMUX_BUILD_TUPLE}" \
        --enable-shared \
        ${CONF} \
        CFLAGS="${CFLAGS}" \
        CPPFLAGS="${CPPFLAGS}" \
        LDFLAGS="${LDFLAGS}" \
        LIBCRYPT_LIBS="${LIBCRYPT_LIBS:-}" \
        2>&1 | tee configure.log \
        || _die "configure failed. See: ${TERMUX_PKG_BUILDDIR}/configure.log"
    _ok "configure finished."
}

# =============================================================================
# §16  termux_step_post_make_install
# =============================================================================
termux_step_post_make_install() {
    # -- §16.1  Convenience symlinks ----------------------------------------
    _info "Creating convenience symlinks ..."
    (
        cd "${TERMUX_PREFIX}/bin"
        ln -sf "idle${_MAJOR_VERSION}"         idle
        ln -sf "python${_MAJOR_VERSION}"        python
        ln -sf "python${_MAJOR_VERSION}-config" python-config
        ln -sf "pydoc${_MAJOR_VERSION}"         pydoc
    )
    if [[ -d "${TERMUX_PREFIX}/share/man/man1" ]]; then
        ln -sf "python${_MAJOR_VERSION}.1" \
               "${TERMUX_PREFIX}/share/man/man1/python.1" 2>/dev/null || true
    fi

    # -- §16.2  Debian packaging helpers ------------------------------------
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
    else
        _warn "debpython/debpython not found — skipping helper install."
    fi
}

# =============================================================================
# §17  termux_step_post_massage
# =============================================================================
termux_step_post_massage() {
    if [[ "$_OPT_SKIP_VERIFY" == "true" ]]; then
        _warn "Module verification skipped (--skip-verify)."
        return 0
    fi

    _info "Verifying critical extension modules ..."
    local dynload="${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/lib-dynload"
    local failed=0

    [[ -d "$dynload" ]] || _die "lib-dynload directory not found: $dynload"

    for module in "${_REQUIRED_MODULES[@]}"; do
        local found
        found="$(find "$dynload" -name "${module}.*.so" 2>/dev/null | head -1)"
        if [[ -z "$found" ]]; then
            _error "Module NOT built: $module"
            (( failed++ )) || true
        else
            _ok "Module OK: $(basename "$found")"
        fi
    done

    if (( failed > 0 )); then
        _error "${failed} critical module(s) failed to build."
        _die "Check configure.log and build output for details."
    fi
}

# =============================================================================
# §18  termux_step_create_debscripts
# =============================================================================
termux_step_create_debscripts() {
    local outdir="${1:-.}"
    local postinst="${outdir}/postinst"

    _info "Generating postinst script ..."

    # Use printf to write the script; avoids heredoc indentation ambiguity.
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -e\n\n'
        printf '# Remove unmanaged pip left by a previous Python install.\n'
        printf '# Termux ships a patched pip; upstream pip must not linger.\n'
        printf '_pip_managed_by_pkg() {\n'
        printf '    case "%s" in\n' "${TERMUX_PACKAGE_FORMAT}"
        printf '        debian) [[ -f "%s/var/lib/dpkg/info/python-pip.list" ]] ;;\n' "${TERMUX_PREFIX}"
        printf '        pacman) ls "%s/var/lib/pacman/local/python-pip-"* &>/dev/null ;;\n' "${TERMUX_PREFIX}"
        printf '        *)      return 1 ;;\n'
        printf '    esac\n'
        printf '}\n\n'
        printf 'if [[ -f "%s/bin/pip" ]] && ! _pip_managed_by_pkg; then\n' "${TERMUX_PREFIX}"
        printf '    echo "Removing unmanaged pip installation..."\n'
        printf '    rm -f  "%s/bin/pip" \\\n'           "${TERMUX_PREFIX}"
        printf '           "%s/bin/pip3"* \\\n'         "${TERMUX_PREFIX}"
        printf '           "%s/bin/easy_install" \\\n'  "${TERMUX_PREFIX}"
        printf '           "%s/bin/easy_install-3"*\n'  "${TERMUX_PREFIX}"
        printf '    rm -rf "%s/lib/python%s/site-packages/pip"\n' \
               "${TERMUX_PREFIX}" "${_MAJOR_VERSION}"
        printf '    rm -rf "%s/lib/python%s/site-packages/pip-"*.dist-info\n' \
               "${TERMUX_PREFIX}" "${_MAJOR_VERSION}"
        printf 'fi\n\n'
        printf 'if [[ ! -f "%s/bin/pip" ]]; then\n' "${TERMUX_PREFIX}"
        printf '    echo\n'
        printf '    echo "== Note: pip is now a separate package =="\n'
        printf '    echo "   pkg install python-pip"\n'
        printf '    echo\n'
        printf 'fi\n\n'
        printf '# Notify users upgrading from an older Python minor version.\n'
        printf 'for _old_ver in 3.11 3.12; do\n'
        printf '    if [[ -d "%s/lib/python${_old_ver}/site-packages" ]]; then\n' \
               "${TERMUX_PREFIX}"
        printf '        echo\n'
        printf '        echo "NOTE: Python updated to %s."\n' "${_MAJOR_VERSION}"
        printf '        echo "NOTE: Run '"'"'pkg upgrade'"'"' to update system Python packages."\n'
        printf '        echo "NOTE: Packages installed with pip must be reinstalled."\n'
        printf '        echo\n'
        printf '        break\n'
        printf '    fi\n'
        printf 'done\n\n'
        printf 'exit 0\n'
    } > "$postinst"

    chmod 0755 "$postinst"

    # Validate generated script syntax immediately.
    bash -n "$postinst" || _die "Generated postinst has syntax errors: $postinst"
    _ok "postinst written and validated."

    # pacman also needs a postupg hook.
    if [[ "${TERMUX_PACKAGE_FORMAT}" == "pacman" ]]; then
        printf 'post_install\n' > "${outdir}/postupg"
        _ok "postupg written."
    fi
}

# =============================================================================
# §19  MAIN
# =============================================================================
main() {
    _parse_args "$@"
    _setup_env

    _section "Termux Python ${TERMUX_PKG_VERSION} — Build"
    printf "  %-16s %s\n" "Version:"    "${TERMUX_PKG_VERSION} (rev ${TERMUX_PKG_REVISION})"
    printf "  %-16s %s\n" "API Level:"  "${TERMUX_PKG_API_LEVEL}"
    printf "  %-16s %s\n" "Arch:"       "${TERMUX_ARCH}"
    printf "  %-16s %s\n" "Host:"       "${TERMUX_HOST_PLATFORM}"
    printf "  %-16s %s\n" "Build:"      "${TERMUX_BUILD_TUPLE}"
    printf "  %-16s %s\n" "Prefix:"     "${TERMUX_PREFIX}"
    printf "  %-16s %s\n" "On-device:"  "${TERMUX_ON_DEVICE_BUILD}"
    printf "  %-16s %s\n" "Jobs:"       "${TERMUX_PKG_MAKE_PROCESSES}"
    printf "  %-16s %s\n" "Clean:"      "${_OPT_CLEAN}"
    printf "  %-16s %s\n" "Skip-verify:" "${_OPT_SKIP_VERIFY}"
    echo

    _section "Step 1/14 — Tool Check"
    _check_tools

    _section "Step 2/14 — Patch Validation"
    _validate_patches

    if [[ "$_OPT_CLEAN" == "true" ]]; then
        _section "Step 3/14 — Clean"
        _info "Removing: $TERMUX_PKG_SRCDIR"
        rm -rf "$TERMUX_PKG_SRCDIR"
        _info "Removing: $TERMUX_PKG_BUILDDIR"
        rm -rf "$TERMUX_PKG_BUILDDIR"
        _ok "Clean complete."
    fi

    _section "Step 4/14 — Create Directories"
    mkdir -p "$TERMUX_PKG_CACHEDIR" "$TERMUX_PKG_SRCDIR" "$TERMUX_PKG_BUILDDIR"
    _ok "Directories ready."

    _section "Step 5/14 — Download Sources"
    _download "$_PYTHON_URL" \
        "${TERMUX_PKG_CACHEDIR}/Python-${TERMUX_PKG_VERSION}.tgz" \
        "$_PYTHON_SHA256"
    _download "$_DEBPYTHON_URL" \
        "${TERMUX_PKG_CACHEDIR}/python3-defaults-${_DEBPYTHON_COMMIT}.tar.gz" \
        "$_DEBPYTHON_SHA256"

    _section "Step 6/14 — Unpack"
    df -h
    ls -lh "${TERMUX_PKG_CACHEDIR}/Python-${TERMUX_PKG_VERSION}.tgz"

    _info "Unpacking Python-${TERMUX_PKG_VERSION}.tgz ..."
    rm -rf "$TERMUX_PKG_SRCDIR"
    mkdir -p "$TERMUX_PKG_SRCDIR"
    tar -xzf "${TERMUX_PKG_CACHEDIR}/Python-${TERMUX_PKG_VERSION}.tgz" \
        --strip-components=1 -C "$TERMUX_PKG_SRCDIR" \
        || _die "Failed to unpack Python tarball."
    _ok "CPython source unpacked."

    _info "Unpacking python3-defaults tarball ..."
    tar -xf "${TERMUX_PKG_CACHEDIR}/python3-defaults-${_DEBPYTHON_COMMIT}.tar.gz" \
        -C "$TERMUX_PKG_SRCDIR" \
        || _die "Failed to unpack python3-defaults tarball."
    _ok "python3-defaults unpacked."

    _section "Step 7/14 — Post-Get-Source"
    cd "$TERMUX_PKG_SRCDIR"
    termux_step_post_get_source

    _section "Step 8/14 — Apply Patches"
    cd "$TERMUX_PKG_SRCDIR"
    _apply_patches

    _section "Step 9/14 — Pre-Configure"
    termux_step_pre_configure

    _section "Step 10/14 — Configure"
    _do_configure

    _section "Step 11/14 — Build"
    _info "make -j${TERMUX_PKG_MAKE_PROCESSES} ..."
    cd "$TERMUX_PKG_BUILDDIR"
    make -j"${TERMUX_PKG_MAKE_PROCESSES}" \
        || _die "make failed. Review build output above."
    _ok "Build complete."

    _section "Step 12/14 — Install"
    make install || _die "make install failed."
    _ok "Install complete."

    _section "Step 13/14 — Post-Install + Module Verification"
    termux_step_post_make_install
    termux_step_post_massage

    _section "Step 14/14 — Package Scripts + Cleanup"
    termux_step_create_debscripts "$TERMUX_PKG_BUILDDIR"

    _info "Removing test trees to save space ..."
    rm -rf \
        "${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/test"    \
        "${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/"*/test  \
        "${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/"*/tests

    # nullglob prevents the glob from expanding to a literal string when
    # site-packages is empty, which would cause a spurious rm error under set -e.
    shopt -s nullglob
    local -a sp_files=("${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/site-packages/"*)
    shopt -u nullglob
    (( ${#sp_files[@]} > 0 )) && rm -rf "${sp_files[@]}"

    _ok "Cleanup complete."

    _section "Build Successful"
    printf "  Python %s installed to: %s\n" "${TERMUX_PKG_VERSION}" "${TERMUX_PREFIX}"
    printf "  Test with: python%s --version\n\n" "${_MAJOR_VERSION}"
}

# Invoke main only when executed directly; skip when sourced by build-package.sh.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
