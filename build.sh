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
readonly -a _REQUIRED_MODULES=(_bz2 _curses _lzma _sqlite3 _ssl zlib)

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
# On a macOS-14 (arm64) runner building aarch64-linux-android, the target ELF
# binary cannot be run — module verification must be skipped automatically.
_is_cross_compiling() {
    [[ "$TERMUX_ON_DEVICE_BUILD" != "true" ]]
}

# =============================================================================
# §8  ENVIRONMENT DETECTION + DEFAULTS
# =============================================================================
_setup_env() {
    # ── Prefix ────────────────────────────────────────────────────────────────
    # Workflow sets PREFIX=${{ github.workspace }}/prefix; pick that up.
    [[ -z "${TERMUX_PREFIX:-}" ]] && \
        export TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

    # ── API level ─────────────────────────────────────────────────────────────
    # Workflow sets TERMUX_PKG_API_LEVEL=35 in env:
    [[ -z "${TERMUX_PKG_API_LEVEL:-}" ]] && export TERMUX_PKG_API_LEVEL=35

    # ── Arch (detect then always normalise) ───────────────────────────────────
    # Workflow does not set TERMUX_ARCH; uname -m on macos-14 returns "arm64"
    # which _normalize_arch converts to "aarch64" — the correct Android target.
    [[ -z "${TERMUX_ARCH:-}" ]] && { TERMUX_ARCH="$(uname -m)"; export TERMUX_ARCH; }
    TERMUX_ARCH="$(_normalize_arch "$TERMUX_ARCH")"
    export TERMUX_ARCH

    # ── Toolchain + package format ────────────────────────────────────────────
    # Workflow exports TERMUX_STANDALONE_TOOLCHAIN pointing at the NDK toolchain.
    [[ -z "${TERMUX_STANDALONE_TOOLCHAIN:-}" ]] && \
        export TERMUX_STANDALONE_TOOLCHAIN="${TERMUX_PREFIX}"
    [[ -z "${TERMUX_PACKAGE_FORMAT:-}" ]] && export TERMUX_PACKAGE_FORMAT="debian"

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
    [[ -z "${PATCHED_SOURCE_URL:-}" ]] && \
        _die "PATCHED_SOURCE_URL is not set. Export it before running this script."
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
    trap 'rm -f "$tmp"' RETURN INT TERM

    mkdir -p "$(dirname "$dest")"

    if [[ -f "$dest" ]]; then
        if [[ -z "$expected" ]]; then
            _ok "Cache hit: $(basename "$dest") (no checksum — reusing)"; return 0
        fi
        local actual; actual="$(_sha256 "$dest")"
        if [[ "$actual" == "$expected" ]]; then
            _ok "Cache hit: $(basename "$dest")"; return 0
        fi
        _warn "SHA256 mismatch on cached file — re-downloading"
        rm -f "$dest"
    fi

    _info "Downloading: $url"
    if command -v curl &>/dev/null; then
        curl -fL --retry 5 --retry-delay 2 --connect-timeout 30 \
             --progress-bar -o "$tmp" "$url" || _die "curl failed: $url"
    elif command -v wget &>/dev/null; then
        wget --tries=5 --timeout=30 -q --show-progress \
             -O "$tmp" "$url" || _die "wget failed: $url"
    else
        _die "Neither curl nor wget found."
    fi

    if [[ -n "$expected" ]]; then
        local actual; actual="$(_sha256 "$tmp")"
        [[ "$actual" == "$expected" ]] || {
            rm -f "$tmp"
            _error "SHA256 mismatch — expected=$expected got=$actual"
            _die "Download integrity check failed."
        }
    fi

    mv "$tmp" "$dest"
    _ok "Downloaded: $(basename "$dest")"
}

# =============================================================================
# §10  TOOL CHECK
# =============================================================================
_check_tools() {
    _info "Checking required build tools ..."
    local -a required=(make tar pkg-config)
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
    (( missing > 0 )) && _die "${missing} required tool(s) missing — install them and retry."
    _ok "All required tools present."
}

# =============================================================================
# §11  PRE-CONFIGURE FLAGS
# =============================================================================
_setup_flags() {
    local _BUILD_PYTHON
    _BUILD_PYTHON="$(command -v "python${_MAJOR_VERSION}" \
                   || command -v python3 \
                   || { _warn "No host Python found; configure may fail."; \
                        echo "python${_MAJOR_VERSION}"; })"
    _info "Host Python: $_BUILD_PYTHON"

    # ── CFLAGS ────────────────────────────────────────────────────────────────
    CFLAGS="${CFLAGS:-}"
    CFLAGS="${CFLAGS/-Oz/-O3}"                       # -Oz breaks Python on Android
    [[ "$CFLAGS" =~ -O[0-9s] ]] || CFLAGS+=" -O3"
    CFLAGS+=" -fno-semantic-interposition"            # improves call-through-plt perf

    # ── LDFLAGS ───────────────────────────────────────────────────────────────
    LDFLAGS="${LDFLAGS:-}"
    LDFLAGS="${LDFLAGS//-Wl,--as-needed/}"            # breaks extension module linking

    # ── CPPFLAGS + sysroot include / lib ─────────────────────────────────────
    CPPFLAGS="${CPPFLAGS:-}"
    local _sysroot_inc="${TERMUX_STANDALONE_TOOLCHAIN}/sysroot/usr/include"
    local _sysroot_lib="${TERMUX_STANDALONE_TOOLCHAIN}/sysroot/usr/lib"
    [[ -d "${_sysroot_inc}" ]] && CPPFLAGS+=" -I${_sysroot_inc}"
    if [[ -d "${_sysroot_lib}" ]]; then
        local _lib_suffix=""
        [[ "$TERMUX_ARCH" == "x86_64" ]] && _lib_suffix="64"
        LDFLAGS+=" -L${_sysroot_lib}${_lib_suffix}"
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
    CONF_FLAGS+=" --with-system-ffi"
    CONF_FLAGS+=" --with-system-expat"
    CONF_FLAGS+=" --without-ensurepip"
    CONF_FLAGS+=" --enable-loadable-sqlite-extensions"

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
    LDFLAGS+=" -landroid-posix-semaphore -landroid-spawn"
    export LIBCRYPT_LIBS="-lcrypt"
    export CFLAGS CPPFLAGS LDFLAGS CONF_CACHE CONF_FLAGS
}

# =============================================================================
# §12  CONFIGURE
# =============================================================================
_do_configure() {
    mkdir -p "$TERMUX_PKG_BUILDDIR"
    cd "$TERMUX_PKG_BUILDDIR"
    _info "Running ./configure ..."
    # shellcheck disable=SC2086
    "${TERMUX_PKG_SRCDIR}/configure" \
        --prefix="${TERMUX_PREFIX}"        \
        --host="${TERMUX_HOST_PLATFORM}"   \
        --build="${TERMUX_BUILD_TUPLE}"    \
        --enable-shared                    \
        ${CONF_CACHE}                      \
        ${CONF_FLAGS}                      \
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
    (( failed > 0 )) && _die "${failed} required module(s) missing."
    _ok "All required modules present."
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

    # Stage installed prefix into deb tree
    local prefix_stripped="${TERMUX_PREFIX#/}"
    local staging="${debdir}/${prefix_stripped}"
    mkdir -p "$(dirname "$staging")"
    cp -a "${TERMUX_PREFIX}" "$staging"

    # Generate postinst
    local postinst="${ctrl}/postinst"
    {
        printf '#!/usr/bin/env bash\nset -e\n\n'
        printf '_pip_managed_by_pkg() {\n'
        printf '    case "%s" in\n'                                                         "${TERMUX_PACKAGE_FORMAT}"
        printf '        debian) [[ -f "%s/var/lib/dpkg/info/python-pip.list" ]] ;;\n'      "${TERMUX_PREFIX}"
        printf '        pacman) ls "%s/var/lib/pacman/local/python-pip-"* &>/dev/null ;;\n' "${TERMUX_PREFIX}"
        printf '        *)      return 1 ;;\n'
        printf '    esac\n}\n\n'
        printf 'if [[ -f "%s/bin/pip" ]] && ! _pip_managed_by_pkg; then\n'                 "${TERMUX_PREFIX}"
        printf '    echo "Removing unmanaged pip..."\n'
        printf '    rm -f "%s/bin/pip" "%s/bin/pip3"* "%s/bin/easy_install"*\n'            "${TERMUX_PREFIX}" "${TERMUX_PREFIX}" "${TERMUX_PREFIX}"
        printf '    rm -rf "%s/lib/python%s/site-packages/pip"*\n'                         "${TERMUX_PREFIX}" "${_MAJOR_VERSION}"
        printf 'fi\n\n'
        printf 'if [[ ! -f "%s/bin/pip" ]]; then\n'                                        "${TERMUX_PREFIX}"
        printf '    echo "== Note: pip is now a separate package: pkg install python-pip =="\n'
        printf 'fi\n\n'
        printf 'for _old_ver in 3.11 3.12; do\n'
        printf '    if [[ -d "%s/lib/python${_old_ver}/site-packages" ]]; then\n'          "${TERMUX_PREFIX}"
        printf '        echo "NOTE: Python updated to %s. Reinstall pip packages."\n'       "${_MAJOR_VERSION}"
        printf '        break\n'
        printf '    fi\n'
        printf 'done\nexit 0\n'
    } > "$postinst"
    chmod 0755 "$postinst"
    bash -n "$postinst" || _die "Generated postinst has syntax errors."

    mkdir -p "$OUTPUT_DIR"
    local debout="${OUTPUT_DIR}/${debname}"

    # Prefer dpkg-deb (available on Linux runners).
    # On macOS the workflow does not install dpkg, so we build the .deb manually.
    # BSD tar does not support -J; use the `xz` binary directly so we stay
    # compatible with both GNU tar (Linux) and BSD tar (macOS).
    if command -v dpkg-deb &>/dev/null; then
        dpkg-deb --build "$debdir" "$debout"
    else
        _warn "dpkg-deb not available; building .deb manually ..."
        local tmp; tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' RETURN

        echo "2.0" > "${tmp}/debian-binary"

        # control.tar.gz — always gz; small and universally supported
        tar -czf "${tmp}/control.tar.gz" -C "$ctrl" .

        # data.tar.xz — compress with xz binary, not tar -J, for macOS compat
        tar -cf "${tmp}/data.tar" --exclude='./DEBIAN' -C "$debdir" .
        xz -z -T0 "${tmp}/data.tar"           # produces data.tar.xz in-place
        # -T0 uses all available threads (respects CPU_COUNT implicitly)

        # ar — prefer GNU ar (binutils); fall back to BSD ar (both work for .deb)
        local _ar="ar"
        command -v gar &>/dev/null && _ar="gar"   # Homebrew gnu-ar shim name
        "${_ar}" -rcs "$debout" \
            "${tmp}/debian-binary" \
            "${tmp}/control.tar.gz" \
            "${tmp}/data.tar.xz"
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

    _section "Step 1/10 — Tool Check"
    _check_tools

    if [[ "$_OPT_CLEAN" == "true" ]]; then
        _section "Step 2/10 — Clean"
        rm -rf "$TERMUX_PKG_SRCDIR" "$TERMUX_PKG_BUILDDIR"
        _ok "Clean complete."
    else
        _info "Step 2/10 — Clean skipped (pass --clean to wipe build dirs)."
    fi

    _section "Step 3/10 — Download Patched Source"
    mkdir -p "$TERMUX_PKG_CACHEDIR" "$TERMUX_PKG_SRCDIR"
    _download "${PATCHED_SOURCE_URL}" "${TERMUX_PKG_CACHEDIR}/${_PATCHED_TARBALL}"

    _section "Step 4/10 — Unpack Patched Source"
    _info "Unpacking ${_PATCHED_TARBALL} ..."
    rm -rf "$TERMUX_PKG_SRCDIR"
    mkdir -p "$TERMUX_PKG_SRCDIR"
    tar -xJf "${TERMUX_PKG_CACHEDIR}/${_PATCHED_TARBALL}" \
        --strip-components=1 -C "$TERMUX_PKG_SRCDIR" \
        || _die "Failed to unpack patched source tarball."
    _ok "Patched source unpacked."

    _section "Step 5/10 — Setup Compiler Flags"
    _setup_flags

    _section "Step 6/10 — Configure"
    _do_configure

    _section "Step 7/10 — Build"
    _info "make -j${TERMUX_PKG_MAKE_PROCESSES} ..."
    cd "$TERMUX_PKG_BUILDDIR"
    make -j"${TERMUX_PKG_MAKE_PROCESSES}" || _die "make failed."
    _ok "Build complete."

    _section "Step 8/10 — Install"
    make install || _die "make install failed."
    _ok "Install complete."

    _section "Step 9/10 — Post-Install + Module Verification"
    _post_install
    _verify_modules

    _section "Step 10/10 — Package"
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
    (( ${#sp_files[@]} > 0 )) && rm -rf "${sp_files[@]}"

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
