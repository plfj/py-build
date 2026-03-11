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
#   Options:
#     --help             Show this help and exit
#     --clean            Wipe build/src dirs before starting
#     --skip-verify      Skip post-install module verification
#     --jobs N           Override parallel make job count
#     --source-url URL   URL to python-*-patched-src.tar.xz
#                        (defaults to PATCHED_SOURCE_URL env var)
#
# The following environment variables must be set (done by the CI workflow):
#   CC, CXX, AR, AS, LD, NM, RANLIB, STRIP, OBJDUMP
#   CFLAGS, CXXFLAGS, LDFLAGS, SYSROOT
#   TERMUX_ARCH, TERMUX_PKG_API_LEVEL, TERMUX_PREFIX
#   TERMUX_STANDALONE_TOOLCHAIN   (NDK toolchain dir, not output prefix)
#   ANDROID_NDK_HOME
#
# Output: $TERMUX_PREFIX tree (populated), plus a .deb at $OUTPUT_DIR
# =============================================================================
set -euo pipefail

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
# §2  OPTION VARIABLES
# =============================================================================
_OPT_CLEAN=false
_OPT_SKIP_VERIFY=false
_OPT_JOBS=""
_OPT_SOURCE_URL="${PATCHED_SOURCE_URL:-}"

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
# §4  ARGUMENT PARSING
# =============================================================================
_parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --help|-h)
                grep '^# ' "$0" | head -25 | sed 's/^# \{0,2\}//'
                exit 0 ;;
            --clean)        _OPT_CLEAN=true ;;
            --skip-verify)  _OPT_SKIP_VERIFY=true ;;
            --source-url)
                [[ -n "${2:-}" ]] || _die "--source-url requires a URL"
                _OPT_SOURCE_URL="$2"; shift ;;
            --jobs|-j)
                [[ -n "${2:-}" ]] || _die "--jobs requires a numeric argument"
                [[ "$2" =~ ^[1-9][0-9]*$ ]] || _die "--jobs must be a positive integer"
                _OPT_JOBS="$2"; shift ;;
            *) _die "Unknown option: '$1'  (try --help)" ;;
        esac
        shift
    done
}

# =============================================================================
# §5  ARCH -> TRIPLET HELPER
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
# §6  ENVIRONMENT DETECTION + DEFAULTS
# =============================================================================
_setup_env() {
    [[ -z "${TERMUX_PREFIX:-}" ]]        && export TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
    [[ -z "${TERMUX_PKG_API_LEVEL:-}" ]] && export TERMUX_PKG_API_LEVEL=35
    [[ -z "${TERMUX_ARCH:-}" ]]          && { TERMUX_ARCH="$(uname -m | sed 's/armv[78]l/arm/')"; export TERMUX_ARCH; }
    [[ -z "${TERMUX_STANDALONE_TOOLCHAIN:-}" ]] && export TERMUX_STANDALONE_TOOLCHAIN="${TERMUX_PREFIX}"
    [[ -z "${TERMUX_PACKAGE_FORMAT:-}" ]]       && export TERMUX_PACKAGE_FORMAT="debian"

    if [[ -z "${TERMUX_ON_DEVICE_BUILD:-}" ]]; then
        if [[ "$(uname -o 2>/dev/null)" == "Android" ]] || [[ -e "/system/bin/app_process" ]]; then
            export TERMUX_ON_DEVICE_BUILD=true
        else
            export TERMUX_ON_DEVICE_BUILD=false
        fi
    fi

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

    TERMUX_PKG_SRCDIR="${TMPDIR:-/tmp}/python-build/src"
    TERMUX_PKG_BUILDDIR="${TMPDIR:-/tmp}/python-build/build"
    TERMUX_PKG_CACHEDIR="${TMPDIR:-/tmp}/python-build/cache"
    OUTPUT_DIR="${OUTPUT_DIR:-${_SCRIPT_DIR}}"
    export TERMUX_PKG_SRCDIR TERMUX_PKG_BUILDDIR TERMUX_PKG_CACHEDIR

    [[ -z "${_OPT_SOURCE_URL}" ]] && \
        _die "No source URL. Set PATCHED_SOURCE_URL env var or pass --source-url."
}

# =============================================================================
# §7  SHA256 + DOWNLOAD
# =============================================================================
_sha256() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        _die "No SHA-256 utility found."
    fi
}

_download() {
    local url="$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    if [[ -f "$dest" ]]; then
        _ok "Cache hit: $(basename "$dest")"; return 0
    fi
    _info "Downloading: $(basename "$dest")"
    local tmp="${dest}.tmp.$$"
    trap 'rm -f "$tmp"' RETURN INT TERM
    if command -v curl &>/dev/null; then
        curl -fL --retry 5 --retry-delay 2 --connect-timeout 30 \
             --progress-bar -o "$tmp" "$url" || _die "curl failed: $url"
    else
        wget --tries=5 --timeout=30 -q --show-progress \
             -O "$tmp" "$url" || _die "wget failed: $url"
    fi
    mv "$tmp" "$dest"
    _ok "Downloaded: $(basename "$dest")"
}

# =============================================================================
# §8  TOOL CHECK
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
        command -v "$t" &>/dev/null || { _error "Missing: $t"; (( missing++ )) || true; }
    done
    (( missing > 0 )) && _die "${missing} required tool(s) missing."
    _ok "All required tools present."
}

# =============================================================================
# §9  PRE-CONFIGURE FLAGS
# =============================================================================
_setup_flags() {
    local _BUILD_PYTHON
    _BUILD_PYTHON="$(command -v "python${_MAJOR_VERSION}" \
                   || command -v python3 \
                   || { _warn "No host Python found; configure may fail."; \
                        echo "python${_MAJOR_VERSION}"; })"
    _info "Host Python: $_BUILD_PYTHON"

    CFLAGS="${CFLAGS:-}"
    CFLAGS="${CFLAGS/-Oz/-O3}"
    [[ "$CFLAGS" =~ -O[0-9s] ]] || CFLAGS+=" -O3"
    CFLAGS+=" -fno-semantic-interposition"

    LDFLAGS="${LDFLAGS:-}"
    LDFLAGS="${LDFLAGS//-Wl,--as-needed/}"

    CPPFLAGS="${CPPFLAGS:-}"
    local _sysroot_inc="${TERMUX_STANDALONE_TOOLCHAIN}/sysroot/usr/include"
    local _sysroot_lib="${TERMUX_STANDALONE_TOOLCHAIN}/sysroot/usr/lib"
    if [[ -d "${_sysroot_inc}" ]]; then
        CPPFLAGS+=" -I${_sysroot_inc}"
    fi
    if [[ -d "${_sysroot_lib}" ]]; then
        local _lib_suffix=""
        [[ "$TERMUX_ARCH" == "x86_64" ]] && _lib_suffix="64"
        LDFLAGS+=" -L${_sysroot_lib}${_lib_suffix}"
    fi

    if [[ "$TERMUX_ON_DEVICE_BUILD" == "true" ]]; then
        local sdk_ver
        sdk_ver="$(getprop ro.build.version.sdk 2>/dev/null || echo "${TERMUX_PKG_API_LEVEL}")"
        CPPFLAGS+=" -D__ANDROID_API__=${sdk_ver}"
    fi

    # ── configure cache vars (unconditional) ──────────────────────────────────
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

    # ── configure flags (-- options) ─────────────────────────────────────────
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
# §10  CONFIGURE
# =============================================================================
_do_configure() {
    mkdir -p "$TERMUX_PKG_BUILDDIR"
    cd "$TERMUX_PKG_BUILDDIR"
    _info "Running ./configure ..."
    # shellcheck disable=SC2086
    "${TERMUX_PKG_SRCDIR}/configure" \
        --prefix="${TERMUX_PREFIX}"      \
        --host="${TERMUX_HOST_PLATFORM}" \
        --build="${TERMUX_BUILD_TUPLE}"  \
        --enable-shared                  \
        ${CONF_CACHE}                    \
        ${CONF_FLAGS}                    \
        CFLAGS="${CFLAGS}"               \
        CPPFLAGS="${CPPFLAGS}"           \
        LDFLAGS="${LDFLAGS}"             \
        LIBCRYPT_LIBS="${LIBCRYPT_LIBS:-}" \
        2>&1 | tee configure.log \
        || _die "configure failed. See: ${TERMUX_PKG_BUILDDIR}/configure.log"
    _ok "configure finished."
}

# =============================================================================
# §11  POST-INSTALL
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
# §12  MODULE VERIFICATION
# =============================================================================
_verify_modules() {
    [[ "$_OPT_SKIP_VERIFY" == "true" ]] && { _warn "Module verification skipped."; return; }
    _info "Verifying required extension modules ..."
    local python_bin="${TERMUX_PREFIX}/bin/python${_MAJOR_VERSION}"
    [[ -x "$python_bin" ]] || { _warn "python${_MAJOR_VERSION} not found; skipping."; return; }
    local failed=0
    for mod in "${_REQUIRED_MODULES[@]}"; do
        if ! "$python_bin" -c "import ${mod}" 2>/dev/null; then
            _error "Missing module: ${mod}"
            (( failed++ )) || true
        fi
    done
    (( failed > 0 )) && _die "${failed} required module(s) missing."
    _ok "All required modules present."
}

# =============================================================================
# §13  CREATE .deb PACKAGE
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
        printf '    case "%s" in\n'                                                    "${TERMUX_PACKAGE_FORMAT}"
        printf '        debian) [[ -f "%s/var/lib/dpkg/info/python-pip.list" ]] ;;\n' "${TERMUX_PREFIX}"
        printf '        pacman) ls "%s/var/lib/pacman/local/python-pip-"* &>/dev/null ;;\n' "${TERMUX_PREFIX}"
        printf '        *)      return 1 ;;\n'
        printf '    esac\n}\n\n'
        printf 'if [[ -f "%s/bin/pip" ]] && ! _pip_managed_by_pkg; then\n'            "${TERMUX_PREFIX}"
        printf '    echo "Removing unmanaged pip..."\n'
        printf '    rm -f "%s/bin/pip" "%s/bin/pip3"* "%s/bin/easy_install"*\n'       "${TERMUX_PREFIX}" "${TERMUX_PREFIX}" "${TERMUX_PREFIX}"
        printf '    rm -rf "%s/lib/python%s/site-packages/pip"*\n'                    "${TERMUX_PREFIX}" "${_MAJOR_VERSION}"
        printf 'fi\n\n'
        printf 'if [[ ! -f "%s/bin/pip" ]]; then\n'                                   "${TERMUX_PREFIX}"
        printf '    echo "== Note: pip is now a separate package: pkg install python-pip =="\n'
        printf 'fi\n\n'
        printf 'for _old_ver in 3.11 3.12; do\n'
        printf '    if [[ -d "%s/lib/python' "${TERMUX_PREFIX}"
        printf '${_old_ver}/site-packages" ]]; then\n'
        printf '        echo "NOTE: Python updated to %s. Reinstall pip packages."\n'  "${_MAJOR_VERSION}"
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
        _warn "dpkg-deb not available; building .deb manually with ar + tar ..."
        local tmp; tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' RETURN
        echo "2.0" > "${tmp}/debian-binary"
        tar -czf "${tmp}/control.tar.gz" -C "$ctrl" .
        tar -cJf "${tmp}/data.tar.xz" --exclude='./DEBIAN' -C "$debdir" .
        ar -rcs "$debout" \
            "${tmp}/debian-binary" \
            "${tmp}/control.tar.gz" \
            "${tmp}/data.tar.xz"
    fi

    local size; size="$(du -sh "$debout" | cut -f1)"
    _ok "Package: ${debout}  (${size})"
    echo "$debout"
}

# =============================================================================
# §14  MAIN
# =============================================================================
main() {
    _parse_args "$@"
    _setup_env

    _section "Termux Python ${TERMUX_PKG_VERSION} — Build for Android"
    printf "  %-16s %s\n" "Version:"    "${TERMUX_PKG_VERSION} (rev ${TERMUX_PKG_REVISION})"
    printf "  %-16s %s\n" "API Level:"  "${TERMUX_PKG_API_LEVEL}"
    printf "  %-16s %s\n" "Arch:"       "${TERMUX_ARCH}"
    printf "  %-16s %s\n" "Host:"       "${TERMUX_HOST_PLATFORM}"
    printf "  %-16s %s\n" "Build:"      "${TERMUX_BUILD_TUPLE}"
    printf "  %-16s %s\n" "Prefix:"     "${TERMUX_PREFIX}"
    printf "  %-16s %s\n" "On-device:"  "${TERMUX_ON_DEVICE_BUILD}"
    printf "  %-16s %s\n" "Jobs:"       "${TERMUX_PKG_MAKE_PROCESSES}"
    printf "  %-16s %s\n" "Source URL:" "${_OPT_SOURCE_URL}"
    echo

    _section "Step 1/10 — Tool Check"
    _check_tools

    if [[ "$_OPT_CLEAN" == "true" ]]; then
        _section "Step 2/10 — Clean"
        rm -rf "$TERMUX_PKG_SRCDIR" "$TERMUX_PKG_BUILDDIR"
        _ok "Clean complete."
    fi

    _section "Step 3/10 — Download Patched Source"
    mkdir -p "$TERMUX_PKG_CACHEDIR" "$TERMUX_PKG_SRCDIR"
    _download "$_OPT_SOURCE_URL" \
        "${TERMUX_PKG_CACHEDIR}/${_PATCHED_TARBALL}"

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
    make -j"${TERMUX_PKG_MAKE_PROCESSES}" \
        || _die "make failed."
    _ok "Build complete."

    _section "Step 8/10 — Install"
    make install || _die "make install failed."
    _ok "Install complete."

    _section "Step 9/10 — Post-Install + Module Verification"
    _post_install
    _verify_modules

    _section "Step 10/10 — Package"
    _info "Removing test trees ..."
    rm -rf \
        "${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/test"   \
        "${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/"*/test \
        "${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/"*/tests
    shopt -s nullglob
    local -a sp_files=("${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/site-packages/"*)
    shopt -u nullglob
    (( ${#sp_files[@]} > 0 )) && rm -rf "${sp_files[@]}"

    local debfile
    debfile="$(_create_deb)"

    _section "Build Successful"
    printf "  Python %s installed to : %s\n"  "${TERMUX_PKG_VERSION}" "${TERMUX_PREFIX}"
    printf "  .deb package           : %s\n\n" "${debfile}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
