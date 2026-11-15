#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# Waywallen installer for Fedora, Debian/Ubuntu and Arch based distributions
# with KDE Plasma. Run as a normal desktop user, never as root.
#
# Environment overrides:
#   WAYWALLEN_TAG=latest|vX.Y.Z   Waywallen release to build (default: latest).
#                                 Pinned sub-repos are only used when the chosen
#                                 release equals PINNED_TAG.
#   LITO_PROFILE=plain|release    Lito build profile (default: plain)

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

# Toolchain requirements (from the AUR PKGBUILD).
MIN_CLANG_MAJOR=22
MIN_LITO_VERSION='0.8.5'
LLVM_APT_VERSION=22

# Waywallen release and the exact dependency commits known to work with it.
# Update ALL of these together when bumping PINNED_TAG (copy from the AUR PKGBUILD).
PINNED_TAG='v0.6.0'
LUATO_COMMIT='e146c282593b6ee723d9d785789f260b45980967'
WAVSEN_COMMIT='92f37f4748a17a36f946e64c8a4a0880cc9fbe23'
QEXTRA_COMMIT='3fcb45c1722ca434d3abb89832f79d28756ab93f'
QML_MATERIAL_COMMIT='bdb63fb3e61ae03923c484c58183cf17f68cbae4'
VECGLTF_COMMIT='93d66944c5cb4e2897b6bf2eca79fc3fc714b66b'
VRENTO_COMMIT='550e3c1f44ccafc064eb6b4b0b320764f5b65692'
LUA_VERSION='5.5.1'
LUA_SHA256='1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce'

WAYWALLEN_TAG=${WAYWALLEN_TAG:-latest}
LITO_PROFILE=${LITO_PROFILE:-plain}

WORKDIR=''
CURRENT_STEP='Initialisation'
START_TIME=$SECONDS
SUDO_KEEPALIVE_PID=''
SPINNER_PID=''
DISTRO_FAMILY='unknown'
CONDA_EXE_PATH=''
LLVM_BIN_DIR=''

error() { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
info() { printf '%s[INFO]%s %s\n' "$GREEN" "$NC" "$*"; }

# ------------------------------------------------------------
# Cleanup and signal handling
# ------------------------------------------------------------

cleanup() {
        local status=$?
        trap - EXIT ERR INT TERM
        set +e

        if [[ -n "$SPINNER_PID" ]]; then
                kill "$SPINNER_PID" 2>/dev/null
                wait "$SPINNER_PID" 2>/dev/null
                SPINNER_PID=''
        fi

        if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
                kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
                wait "$SUDO_KEEPALIVE_PID" 2>/dev/null
                SUDO_KEEPALIVE_PID=''
        fi

        if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
                rm -rf -- "$WORKDIR"
        fi

        if ((status == 0)); then
                printf '\n'
                info "Installation completed successfully."
                info "Elapsed time: $((SECONDS - START_TIME)) seconds."
        else
                printf '\n' >&2
                error "Installation failed with exit code $status."
                error "Last active step: $CURRENT_STEP"
                error "Temporary build files have been cleaned up."
        fi

        exit "$status"
}

on_error() {
        local status=$?
        local line=${BASH_LINENO[0]:-unknown}

        error "Command failed with exit code $status at line $line."
        error "Step: $CURRENT_STEP"

        return "$status"
}

on_signal() {
        local signal=$1
        local status=$2

        error "Received $signal; stopping installation."

        if [[ -n "$SPINNER_PID" ]]; then
                kill -TERM "$SPINNER_PID" 2>/dev/null || true
        fi

        exit "$status"
}

trap cleanup EXIT
trap on_error ERR
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

# ------------------------------------------------------------
# Spinner and checked command execution
# ------------------------------------------------------------

spinner() {
        local pid=$1
        local label=$2
        local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local i=0

        while kill -0 "$pid" 2>/dev/null; do
                printf '\r\033[K%s %s' "${frames:i%10:1}" "$label"
                i=$((i + 1))
                sleep 0.1
        done

        printf '\r\033[K'
}

run_with_spinner() {
        local label=$1
        shift

        local logfile
        local status

        logfile=$(mktemp "${TMPDIR:-/tmp}/waywallen-log.XXXXXX")

        info "$label"

        "$@" >"$logfile" 2>&1 &
        SPINNER_PID=$!

        spinner "$SPINNER_PID" "$label"

        if wait "$SPINNER_PID"; then
                status=0
        else
                status=$?
        fi

        SPINNER_PID=''

        if ((status == 0)); then
                printf '%s[OK]%s %s\n' "$GREEN" "$NC" "$label"
                rm -f -- "$logfile"
                return 0
        fi

        error "$label failed (exit code $status)."
        printf '%s\n' '-------- Command output --------' >&2
        cat "$logfile" >&2 || true
        printf '%s\n' '------ End command output ------' >&2

        rm -f -- "$logfile"
        return "$status"
}

# ------------------------------------------------------------
# Generic helpers
# ------------------------------------------------------------

# version_ge A B: succeeds when version A >= version B.
version_ge() {
        [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" == "$2" ]]
}

# Resolves the latest stable release tag of a GitHub repo. Tries, in order:
#   1. the /releases/latest redirect (no API, no rate limit)
#   2. the REST API
#   3. the newest git tag (only when the repo has no published release)
latest_release() {
        local repo=$1
        local url=''
        local response=''
        local tag=''

        if url=$(curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2                 -o /dev/null -w '%{url_effective}'                 "https://github.com/${repo}/releases/latest" 2>/dev/null); then
                case "$url" in
                */releases/tag/*)
                        tag=${url##*/releases/tag/}
                        tag=${tag%%[?#]*}
                        ;;
                esac
        fi

        if [[ -z "$tag" ]]; then
                if response=$(curl --proto '=https' --tlsv1.2                         -fsSL --retry 3 --retry-delay 2                         "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null); then
                        tag=$(printf '%s\n' "$response" |
                                sed -nE 's/^[[:space:]]*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' |
                                head -n 1) || true
                fi
        fi

        if [[ -z "$tag" ]]; then
                warn "No published release found for $repo; falling back to its newest git tag."
                tag=$(git ls-remote --tags --refs --sort=-v:refname \
                        "https://github.com/${repo}.git" 2>/dev/null |
                        sed -nE 's#.*refs/tags/(.*)#\1#p' |
                        head -n 1) || true
        fi

        if [[ -z "$tag" ]]; then
                error "Could not determine the latest release for $repo."
                return 1
        fi

        printf '%s\n' "$tag"
}

download_archive() {
        local repo=$1
        local tag=$2
        local destination=$3

        curl --proto '=https' --tlsv1.2 \
                -fSL --retry 3 --retry-delay 2 \
                "https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz" \
                -o "$destination"
}

# pin_dep NAME URL COMMIT: full clone checked out at an exact commit.
# A real clone (not a tarball) is used so Git LFS objects can be fetched.
pin_dep() {
        local name=$1
        local url=$2
        local commit=$3
        local dir="$WORKDIR/deps/$name"

        git clone --quiet "$url" "$dir"
        git -C "$dir" checkout --quiet "$commit"

        if [[ -f "$dir/.gitattributes" ]] && grep -q 'filter=lfs' "$dir/.gitattributes"; then
                git -C "$dir" lfs install --local
                git -C "$dir" lfs pull
        fi
}

fetch_lua() {
        local tarball="$WORKDIR/deps/lua-${LUA_VERSION}.tar.gz"

        curl --proto '=https' --tlsv1.2 -fSL --retry 3 --retry-delay 2 \
                "https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz" -o "$tarball"
        printf '%s  %s\n' "$LUA_SHA256" "$tarball" | sha256sum -c -
        tar -xzf "$tarball" -C "$WORKDIR/deps"
}

# ------------------------------------------------------------
# Distribution detection and dependency installation
# ------------------------------------------------------------

# Prints one of: fedora, debian, arch, unknown.
detect_distro_family() {
        local ids=" ${ID:-} ${ID_LIKE:-} "

        ids=${ids//$'\n'/ }
        ids=${ids//$'\t'/ }

        case "$ids" in
        *" fedora "* | *" rhel "* | *" centos "*) printf 'fedora\n' ;;
        *" arch "*) printf 'arch\n' ;;
        *" debian "* | *" ubuntu "*) printf 'debian\n' ;;
        *) printf 'unknown\n' ;;
        esac
}

install_deps_fedora() {
        info "Installing required build dependencies (Fedora)"

        sudo dnf install -y --skip-unavailable \
                cmake conda gcc gcc-c++ make ninja-build nasm ccache \
                pkgconf-pkg-config pipewire-devel clang clang-tools-extra llvm llvm-devel lld \
                glslang glfw-devel \
                git git-lfs \
                curl gettext \
                rust cargo \
                sqlite-devel libzstd-devel \
                vulkan-headers vulkan-loader vulkan-loader-devel \
                libglvnd-devel libva libva-devel libva-utils mesa-libGL-devel mesa-libEGL-devel mesa-libGLES-devel mesa-libgbm-devel \
                libdrm-devel pulseaudio-libs-devel pulseaudio-libs freetype-devel expat-devel \
                lz4-devel zlib-ng-compat-devel \
                wayland-devel wayland-protocols-devel \
                libX11-devel libXcomposite-devel libXdamage-devel \
                libXext-devel libXfixes-devel libXrandr-devel libXrender-devel \
                libXScrnSaver-devel libxcb-devel libxkbcommon-devel \
                alsa-lib-devel gtk3-devel nss-devel \
                gbm protobuf-compiler \
                qt6-qtbase-private-devel \
                qt6-qtdeclarative-private-devel \
                qt6-qtbase-devel \
                qt6-qtdeclarative-devel \
                qt6-qtwebsockets-devel \
                qt6-qttools-devel \
                qt6-qtgrpc-devel \
                qt6-qtshadertools-devel \
                ffmpeg-free-devel libdav1d-devel \
                plasma-workspace kpackagetool6
}

# Adds the official apt.llvm.org repository and installs LLVM/Clang/LLD 22.
install_llvm_apt() {
        local codename=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
        local keyring=/etc/apt/keyrings/apt.llvm.org.asc
        local suite

        if [[ -z "$codename" ]]; then
                error "Could not determine the distribution codename for the LLVM repository."
                return 1
        fi

        suite="llvm-toolchain-${codename}-${LLVM_APT_VERSION}"

        info "Adding the official LLVM apt repository ($suite)"

        sudo apt-get install -y ca-certificates curl gnupg

        # Make sure LLVM publishes this version for this release.
        if ! curl --proto '=https' --tlsv1.2 -fsSI \
                "https://apt.llvm.org/${codename}/dists/${suite}/Release" >/dev/null 2>&1; then
                error "apt.llvm.org has no LLVM ${LLVM_APT_VERSION} repository for '${codename}'."
                error "Install clang >= ${MIN_CLANG_MAJOR} manually and re-run the script."
                return 1
        fi

        sudo install -d -m 755 /etc/apt/keyrings
        curl --proto '=https' --tlsv1.2 -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key |
                sudo tee "$keyring" >/dev/null

        printf 'deb [signed-by=%s] https://apt.llvm.org/%s/ %s main\n' \
                "$keyring" "$codename" "$suite" |
                sudo tee /etc/apt/sources.list.d/apt-llvm-org.list >/dev/null

        sudo apt-get update

        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
                "clang-${LLVM_APT_VERSION}" \
                "clang-tools-${LLVM_APT_VERSION}" \
                "lld-${LLVM_APT_VERSION}" \
                "llvm-${LLVM_APT_VERSION}" \
                "llvm-${LLVM_APT_VERSION}-dev"

        LLVM_BIN_DIR="/usr/lib/llvm-${LLVM_APT_VERSION}/bin"
}

install_deps_debian() {
        info "Installing required build dependencies (Debian/Ubuntu)"

        local packages=(
                # Toolchain (clang/llvm/lld come from apt.llvm.org below)
                build-essential cmake gcc g++ make ninja-build nasm ccache
                pkg-config
                rustc cargo libssl-dev
                git git-lfs curl gettext
                libsqlite3-dev libzstd-dev
                # Shaders, windowing, GPU
                glslang-tools glslang-dev libglfw3-dev
                libvulkan-dev vulkan-tools
                libglvnd-dev libgl-dev libegl-dev libgles-dev libgbm-dev
                libva-dev vainfo libdrm-dev
                # Audio and multimedia
                libpipewire-0.3-dev libpulse-dev libasound2-dev
                libavcodec-dev libavformat-dev libavutil-dev
                libswscale-dev libswresample-dev libdav1d-dev
                # Misc libraries
                libfreetype-dev libexpat1-dev liblz4-dev zlib1g-dev
                libgtk-3-dev libnss3-dev
                protobuf-compiler libprotobuf-dev
                # Wayland / X11
                libwayland-dev wayland-protocols libxkbcommon-dev
                libx11-dev libxcomposite-dev libxdamage-dev libxext-dev
                libxfixes-dev libxrandr-dev libxrender-dev libxss-dev
                libxcb1-dev
                # Qt 6
                qt6-base-dev qt6-base-private-dev
                qt6-declarative-dev qt6-declarative-private-dev
                qt6-websockets-dev qt6-tools-dev qt6-tools-dev-tools
                qt6-l10n-tools qt6-grpc-dev qt6-shadertools-dev
                # KDE Plasma / KDE Frameworks 6
                plasma-workspace plasma-workspace-dev
                libkf6package-dev kpackagetool6
        )

        local available=()
        local missing=()
        local pkg

        sudo apt-get update

        # apt aborts on unknown package names, so filter the list first.
        for pkg in "${packages[@]}"; do
                if apt-cache show "$pkg" >/dev/null 2>&1; then
                        available+=("$pkg")
                else
                        missing+=("$pkg")
                fi
        done

        if ((${#missing[@]} > 0)); then
                local IFS=' '
                warn "Packages not available on this release (skipped): ${missing[*]}"
        fi

        sudo env DEBIAN_FRONTEND=noninteractive \
                apt-get install -y "${available[@]}"

        install_llvm_apt
}

install_deps_arch() {
        info "Installing required build dependencies (Arch)"

        local packages=(
                # Toolchain (base-devel provides gcc, make, pkgconf, ...)
                base-devel cmake gcc make ninja nasm ccache pkgconf
                clang llvm lld rust
                git git-lfs curl gettext
                sqlite zstd
                # Shaders, windowing, GPU (mesa ships GL/EGL/GLES/GBM headers)
                glslang glfw vulkan-headers vulkan-icd-loader
                libglvnd mesa libva libva-utils libdrm
                # Audio and multimedia
                pipewire libpulse alsa-lib ffmpeg dav1d
                # Misc libraries
                freetype2 expat lz4 zlib gtk3 nss protobuf
                # Wayland / X11
                wayland wayland-protocols libxkbcommon
                libx11 libxcomposite libxdamage libxext libxfixes
                libxrandr libxrender libxss libxcb
                # Qt 6 (private headers are included in the base packages)
                qt6-base qt6-declarative qt6-websockets qt6-tools
                qt6-grpc qt6-shadertools qt6-wayland
                # KDE Plasma / KDE Frameworks 6 (kpackagetool6 is in kpackage)
                plasma-workspace kpackage
        )

        local available=()
        local missing=()
        local pkg

        # pacman aborts on unknown targets, so filter the list first.
        for pkg in "${packages[@]}"; do
                if pacman -Si "$pkg" >/dev/null 2>&1; then
                        available+=("$pkg")
                else
                        missing+=("$pkg")
                fi
        done

        if ((${#missing[@]} > 0)); then
                local IFS=' '
                warn "Packages not found in the sync databases (skipped): ${missing[*]}"
                warn "If this looks wrong, run 'sudo pacman -Syu' and retry."
        fi

        sudo pacman -S --needed --noconfirm "${available[@]}"
}

# ------------------------------------------------------------
# Toolchain checks and build environment
# ------------------------------------------------------------

check_toolchain() {
        local clang_major
        local lito_version

        if ! command -v clang >/dev/null 2>&1; then
                error "clang was not found. clang >= ${MIN_CLANG_MAJOR} is required."
                return 1
        fi

        clang_major=$(clang --version | sed -nE 's/.*version ([0-9]+).*/\1/p' | head -n 1)

        if ((${clang_major:-0} < MIN_CLANG_MAJOR)); then
                error "clang >= ${MIN_CLANG_MAJOR} is required (found ${clang_major:-unknown})."
                return 1
        fi
        info "clang $clang_major detected."

        if ! command -v ld.lld >/dev/null 2>&1; then
                error "lld (ld.lld) was not found; it is required by the build."
                return 1
        fi

        lito_version=$(lito --version 2>/dev/null |
                grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)

        if [[ -z "$lito_version" ]]; then
                warn "Could not determine the lito version; need >= ${MIN_LITO_VERSION}."
        elif ! version_ge "$lito_version" "$MIN_LITO_VERSION"; then
                error "lito >= ${MIN_LITO_VERSION} is required (found ${lito_version})."
                return 1
        else
                info "lito $lito_version detected."
        fi
}

setup_build_env() {
        # Only meaningful with rustup; harmless to skip otherwise.
        if command -v rustup >/dev/null 2>&1; then
                export RUSTUP_TOOLCHAIN=stable
        fi

        # Link against system sqlite and zstd instead of bundled copies.
        export LIBSQLITE3_SYS_USE_PKG_CONFIG=1
        export ZSTD_SYS_USE_PKG_CONFIG=1

        # https://github.com/llvm/llvm-project/issues/121709
        export CXXFLAGS="${CXXFLAGS:-}"
        CXXFLAGS="${CXXFLAGS//-Wp,-D_FORTIFY_SOURCE=3/}"

        # --icf=safe is not supported by GNU ld.
        export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-fuse-ld=lld"
}

ensure_conda() {
        local arch
        local installer

        if command -v conda >/dev/null 2>&1; then
                CONDA_EXE_PATH=$(command -v conda)
                return 0
        fi

        if [[ -x "$HOME/miniconda3/bin/conda" ]]; then
                CONDA_EXE_PATH="$HOME/miniconda3/bin/conda"
                return 0
        fi

        case "$(uname -m)" in
        x86_64) arch='x86_64' ;;
        aarch64 | arm64) arch='aarch64' ;;
        *)
                warn "No Miniconda build for $(uname -m); skipping Conda."
                return 0
                ;;
        esac

        installer="$WORKDIR/miniconda.sh"

        run_with_spinner "Downloading Miniconda" \
                curl --proto '=https' --tlsv1.2 -fsSL \
                "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-${arch}.sh" \
                -o "$installer"

        # Batch mode as the normal user; installs to ~/miniconda3.
        run_with_spinner "Installing Miniconda to ~/miniconda3" \
                bash "$installer" -b -p "$HOME/miniconda3"

        CONDA_EXE_PATH="$HOME/miniconda3/bin/conda"
}

# ------------------------------------------------------------
# Preflight checks
# ------------------------------------------------------------

CURRENT_STEP='Preflight checks'

printf '%s\n' \
        "Waywallen installer" \
        "Supported targets: Fedora, Debian/Ubuntu and Arch based Linux with KDE Plasma." \
        "Do not run this script as root."

if ((EUID == 0)); then
        error "Run this script as your normal user, without sudo."
        exit 1
fi

if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
else
        warn "/etc/os-release not found; cannot detect the distribution."
fi

DISTRO_FAMILY=$(detect_distro_family)

case "$DISTRO_FAMILY" in
fedora) info "Detected Fedora based distribution (${PRETTY_NAME:-${ID:-unknown}})." ;;
debian) info "Detected Debian/Ubuntu based distribution (${PRETTY_NAME:-${ID:-unknown}})." ;;
arch) info "Detected Arch based distribution (${PRETTY_NAME:-${ID:-unknown}})." ;;
*)
        warn "Unsupported or unrecognised distribution: ${PRETTY_NAME:-${ID:-unknown}}."
        warn "Dependency installation will be skipped; install them manually if the build fails."
        ;;
esac

for cmd in bash curl tar git sudo mktemp sed head sort sha256sum; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
                error "Required command not found: $cmd"
                exit 1
        fi
done

if [[ -n "${XDG_CURRENT_DESKTOP:-}" ]] &&
        [[ "${XDG_CURRENT_DESKTOP,,}" != *kde* &&
                "${XDG_CURRENT_DESKTOP,,}" != *plasma* ]]; then
        warn "KDE Plasma was not detected as the current desktop."
        warn "Some desktop integration steps may not work."
fi

if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
        error "HOME is unset or does not point to an existing directory."
        exit 1
fi

info "Checking administrative privileges"
sudo -v

# Refresh sudo credentials while lengthy builds are running.
(
        while true; do
                sleep 50
                sudo -n -v || exit
        done
) &
SUDO_KEEPALIVE_PID=$!

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/waywallen-install.XXXXXX")
mkdir -p "$WORKDIR/deps"

mkdir -p \
        "$HOME/.local/bin" \
        "$HOME/.local/share/applications" \
        "$HOME/.local/share/locale" \
        "$HOME/Downloads"

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

# ------------------------------------------------------------
# Install distribution dependencies
# ------------------------------------------------------------

CURRENT_STEP='Installing distribution dependencies'

case "$DISTRO_FAMILY" in
fedora) install_deps_fedora ;;
debian) install_deps_debian ;;
arch) install_deps_arch ;;
*) warn "Skipping dependency installation (unknown distribution)." ;;
esac

# Prefer the versioned LLVM toolchain when it was installed separately.
if [[ -n "$LLVM_BIN_DIR" && -d "$LLVM_BIN_DIR" ]]; then
        export PATH="$LLVM_BIN_DIR:$PATH"
fi

run_with_spinner "Configuring Git LFS" git lfs install

# ------------------------------------------------------------
# Install Lito
# ------------------------------------------------------------

CURRENT_STEP='Installing Lito'

need_lito=1
if command -v lito >/dev/null 2>&1; then
        existing_lito=$(lito --version 2>/dev/null |
                grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
        if [[ -n "$existing_lito" ]] && version_ge "$existing_lito" "$MIN_LITO_VERSION"; then
                info "lito $existing_lito already installed; skipping installer."
                need_lito=0
        fi
fi

if ((need_lito)); then
        run_with_spinner "Downloading Lito installer" \
                curl --proto '=https' --tlsv1.2 -fsSL \
                https://lito.litocpp.org/install.sh \
                -o "$WORKDIR/lito-install.sh"

        run_with_spinner "Installing Lito" \
                bash "$WORKDIR/lito-install.sh"
fi

if ! command -v lito >/dev/null 2>&1; then
        error "Lito was not found on PATH after installation."
        exit 1
fi

CURRENT_STEP='Checking the toolchain'
check_toolchain
setup_build_env

# ------------------------------------------------------------
# Conda (needed by the Open Wallpaper Engine plugin build)
# ------------------------------------------------------------

CURRENT_STEP='Setting up Conda'

ensure_conda

if [[ -n "$CONDA_EXE_PATH" ]]; then
        if ! grep -q 'conda initialize' "$HOME/.bashrc" 2>/dev/null; then
                run_with_spinner "Initializing Conda for the current user" \
                        bash -c '"$1" init bash || true' _ "$CONDA_EXE_PATH"
        else
                info "Conda already initialized in ~/.bashrc, skipping."
        fi
fi

# ------------------------------------------------------------
# Download and build Waywallen
# ------------------------------------------------------------

CURRENT_STEP='Downloading Waywallen'

if [[ "$WAYWALLEN_TAG" == 'latest' ]]; then
        WAYWALLEN_TAG=$(latest_release waywallen/waywallen)
fi
info "Waywallen release: $WAYWALLEN_TAG"

WAYWALLEN_SRC="$WORKDIR/waywallen"

run_with_spinner "Cloning Waywallen $WAYWALLEN_TAG" \
        git clone --quiet --depth 1 --branch "$WAYWALLEN_TAG" \
        https://github.com/waywallen/waywallen.git "$WAYWALLEN_SRC"

cd "$WAYWALLEN_SRC"

# Pin sub-repositories only when building the release they were verified with.
USE_PINS=0
if [[ "$WAYWALLEN_TAG" == "$PINNED_TAG" ]]; then
        USE_PINS=1
else
        info "Waywallen $WAYWALLEN_TAG differs from pinned $PINNED_TAG."
        info "Skipping pinned dependencies; lito will fetch current versions."
fi

if ((USE_PINS)); then
        CURRENT_STEP='Fetching pinned dependencies'

        run_with_spinner "Fetching luato" \
                pin_dep luato https://github.com/litocpp/luato.git "$LUATO_COMMIT"
        run_with_spinner "Fetching wavsen" \
                pin_dep wavsen https://github.com/hypengw/wavsen.git "$WAVSEN_COMMIT"
        run_with_spinner "Fetching QExtra" \
                pin_dep QExtra https://github.com/hypengw/QExtra.git "$QEXTRA_COMMIT"
        run_with_spinner "Fetching vecgltf" \
                pin_dep vecgltf https://github.com/vecren/vecgltf.git "$VECGLTF_COMMIT"
        run_with_spinner "Fetching vrento" \
                pin_dep vrento https://github.com/vecren/vrento.git "$VRENTO_COMMIT"
        run_with_spinner "Fetching QmlMaterial (with LFS files)" \
                pin_dep QmlMaterial https://github.com/hypengw/QmlMaterial.git "$QML_MATERIAL_COMMIT"
        run_with_spinner "Fetching Lua $LUA_VERSION" fetch_lua

        mkdir -p .lito
        cat >.lito/config.toml <<EOF
[patch."https://github.com/litocpp/luato.git"]
path = "$WORKDIR/deps/luato"

[patch."https://github.com/hypengw/wavsen.git"]
path = "$WORKDIR/deps/wavsen"

[patch."https://github.com/hypengw/QExtra.git"]
path = "$WORKDIR/deps/QExtra"

[patch."https://github.com/vecren/vecgltf.git"]
path = "$WORKDIR/deps/vecgltf"

[patch."https://github.com/vecren/vrento.git"]
path = "$WORKDIR/deps/vrento"

[patch."https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz"]
path = "$WORKDIR/deps/lua-${LUA_VERSION}"

[patch."https://github.com/hypengw/QmlMaterial.git"]
path = "$WORKDIR/deps/QmlMaterial"
EOF
fi

CURRENT_STEP='Fetching Waywallen build dependencies'

if ! run_with_spinner "Prefetching Cargo dependencies" \
        cargo fetch --target host-tuple; then
        warn "cargo fetch failed; the build will fetch crates on demand."
fi

run_with_spinner "Fetching Lito dependencies" lito fetch --all-features

CURRENT_STEP='Building Waywallen'

LITO_FLAGS=(--profile "$LITO_PROFILE")
if [[ "$LITO_PROFILE" == 'plain' ]]; then
        LITO_FLAGS+=(--use-env-flags)
fi

run_with_spinner "Building Waywallen ($LITO_PROFILE)" \
        lito build "${LITO_FLAGS[@]}"

CURRENT_STEP='Installing Waywallen'

if [[ -f "$HOME/.local/bin/waywallen" ]]; then
        info "Previous Waywallen installation found; removing before reinstall."
        run_with_spinner "Removing previous Waywallen installation" \
                lito uninstall --prefix "$HOME/.local" --profile "$LITO_PROFILE" ||
                rm -f \
                        "$HOME/.local/bin/waywallen" \
                        "$HOME/.local/bin/waywallen-ui" \
                        "$HOME/.local/share/icons/hicolor/scalable/apps/org.waywallen.waywallen.svg"
fi

run_with_spinner "Installing Waywallen to ~/.local" \
        lito install --prefix "$HOME/.local" --profile "$LITO_PROFILE" --no-build

export QML_IMPORT_PATH="$HOME/.local/lib/qt6/qml"
export LD_LIBRARY_PATH="$HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ------------------------------------------------------------
# Configure Waywallen desktop entry and launcher
# ------------------------------------------------------------

CURRENT_STEP='Creating Waywallen desktop integration'

DESKTOP_FILE="$HOME/.local/share/applications/org.waywallen.waywallen.desktop"

cat >"$HOME/.local/bin/waywallen-start" <<'EOF'
#!/usr/bin/env bash
set -e

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
export QML_IMPORT_PATH="$HOME/.local/lib/qt6/qml"
export LD_LIBRARY_PATH="$HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

exec "$HOME/.local/bin/waywallen" \
    --ui "$HOME/.local/bin/waywallen-ui" \
    --plugin "$HOME/.local/share/waywallen" \
    "$@"
EOF

chmod 755 "$HOME/.local/bin/waywallen-start"

cat >"$DESKTOP_FILE" <<EOF
[Desktop Entry]
Categories=Graphics;Qt;
Comment=Wallpaper Manager for Linux
GenericName=Wallpaper Manager for Linux
Exec=$HOME/.local/bin/waywallen-start
Icon=$HOME/.local/share/icons/hicolor/scalable/apps/org.waywallen.waywallen.svg
Keywords=wallpaper;pipewire;vulkan;
Name=Waywallen
StartupNotify=true
Terminal=false
Type=Application
X-KDE-SubstituteUID=false
EOF

info "Created $DESKTOP_FILE"

# ------------------------------------------------------------
# Download and build waywallen-display
# ------------------------------------------------------------

CURRENT_STEP='Downloading waywallen-display'

LATEST_DISPLAY=$(latest_release waywallen/waywallen-display)
info "Latest waywallen-display release: $LATEST_DISPLAY"

run_with_spinner "Downloading waywallen-display source" \
        download_archive waywallen/waywallen-display "$LATEST_DISPLAY" \
        "$WORKDIR/waywallen-display.tar.gz"

run_with_spinner "Extracting waywallen-display source" \
        tar -xzf "$WORKDIR/waywallen-display.tar.gz" -C "$WORKDIR"

DISPLAY_SRC="$WORKDIR/waywallen-display-${LATEST_DISPLAY#v}"

if [[ ! -d "$DISPLAY_SRC" ]]; then
        error "waywallen-display source directory was not found: $DISPLAY_SRC"
        exit 1
fi

cd "$DISPLAY_SRC"

CURRENT_STEP='Configuring waywallen-display'

run_with_spinner "Configuring waywallen-display with CMake" \
        cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr

CURRENT_STEP='Compiling waywallen-display'

run_with_spinner "Compiling waywallen-display" \
        cmake --build build --parallel "$(nproc)"

CURRENT_STEP='Installing waywallen-display'

run_with_spinner "Installing waywallen-display system-wide" \
        sudo cmake --install build

run_with_spinner "Refreshing system linker cache" sudo ldconfig

# ------------------------------------------------------------
# Build Rust layer-shell component
# ------------------------------------------------------------

CURRENT_STEP='Compiling the Rust layer-shell component'

run_with_spinner "Compiling waywallen-layer-shell" \
        cargo build --release

if [[ ! -f target/release/waywallen-layer-shell ]]; then
        error "The layer-shell executable was not produced."
        exit 1
fi

run_with_spinner "Installing waywallen-layer-shell for the current user" \
        install -Dm755 target/release/waywallen-layer-shell \
        "$HOME/.local/bin/waywallen-layer-shell"

# ------------------------------------------------------------
# Compile translations
# ------------------------------------------------------------

CURRENT_STEP='Compiling layer-shell translations'

shopt -s nullglob
po_files=(po/layer-shell/*.po)
shopt -u nullglob

if ((${#po_files[@]} == 0)); then
        warn "No translation files were found in po/layer-shell."
else
        for po in "${po_files[@]}"; do
                lang=$(basename "$po" .po)
                mo_dir="$HOME/.local/share/locale/$lang/LC_MESSAGES"

                mkdir -p "$mo_dir"

                run_with_spinner "Compiling translation: $lang" \
                        msgfmt -o "$mo_dir/waywallen-layer-shell.mo" "$po"
        done
fi

CURRENT_STEP='Building layer-shell translation targets'

run_with_spinner "Building layer-shell translation targets" \
        cmake --build build --target waywallen-layer-shell-translations

# ------------------------------------------------------------
# Configure and build the KDE Plasma extension
# ------------------------------------------------------------

CURRENT_STEP='Configuring the KDE Plasma extension'

run_with_spinner "Configuring the KDE Plasma extension" \
        cmake -S . -B build-kde \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DWAYWALLEN_DISPLAY_PLUGIN_QML=ON \
        -DWAYWALLEN_DISPLAY_WITH_VULKAN=ON

CURRENT_STEP='Compiling the KDE Plasma extension'

run_with_spinner "Compiling the KDE Plasma extension" \
        cmake --build build-kde --parallel "$(nproc)"

CURRENT_STEP='Packaging the KDE Plasma extension'

run_with_spinner "Packaging the KDE Plasma extension" \
        cmake --build build-kde --target package

# Verify the result rather than passing an unexpanded wildcard to kpackagetool6.
kde_packages=(build-kde/*.zip)

if ((${#kde_packages[@]} == 0)) || [[ ! -f "${kde_packages[0]}" ]]; then
        error "No Plasma package ZIP was produced."
        error "Check the package filename in build-kde/."
        exit 1
fi

CURRENT_STEP='Installing the KDE Plasma package'

if ! command -v kpackagetool6 >/dev/null 2>&1; then
        warn "kpackagetool6 was not found; skipping Plasma wallpaper package install."
        warn "Install it (Debian/Ubuntu: kpackagetool6 or libkf6package-bin, Arch: kpackage)"
        warn "and run: kpackagetool6 --type Plasma/Wallpaper --install ${kde_packages[0]}"
# Upgrade the existing package when already installed; on failure, reinstall.
elif kpackagetool6 --type Plasma/Wallpaper --show org.waywallen.kde \
        >/dev/null 2>&1; then
        info "Existing KDE Plasma integration found; attempting upgrade."

        if run_with_spinner "Upgrading the Plasma wallpaper package" \
                kpackagetool6 --type Plasma/Wallpaper \
                --upgrade "${kde_packages[0]}"; then
                info "KDE Plasma integration upgraded successfully."
        else
                warn "Upgrade failed; removing the existing integration and installing the new package."

                run_with_spinner "Removing existing Plasma wallpaper package" \
                        kpackagetool6 --type Plasma/Wallpaper \
                        -r org.waywallen.kde

                run_with_spinner "Installing the new Plasma wallpaper package" \
                        kpackagetool6 --type Plasma/Wallpaper \
                        --install "${kde_packages[0]}"
        fi
else
        run_with_spinner "Installing the Plasma wallpaper package" \
                kpackagetool6 --type Plasma/Wallpaper \
                --install "${kde_packages[0]}"
fi

CURRENT_STEP='Installing the KDE Plasma extension system-wide'

run_with_spinner "Installing the KDE Plasma extension system-wide" \
        sudo cmake --install build-kde

run_with_spinner "Refreshing system linker cache" sudo ldconfig

# ------------------------------------------------------------
# Download and build Open Wallpaper Engine plugin
# ------------------------------------------------------------

CURRENT_STEP='Downloading Open Wallpaper Engine'

PLUGIN=$(latest_release waywallen/open-wallpaper-engine)
info "Latest Open Wallpaper Engine release: $PLUGIN"

run_with_spinner "Downloading Open Wallpaper Engine source" \
        download_archive waywallen/open-wallpaper-engine "$PLUGIN" \
        "$WORKDIR/open-wallpaper-engine.tar.gz"

run_with_spinner "Extracting Open Wallpaper Engine source" \
        tar -xzf "$WORKDIR/open-wallpaper-engine.tar.gz" -C "$WORKDIR"

PLUGIN_SRC="$WORKDIR/open-wallpaper-engine-${PLUGIN#v}"

if [[ ! -d "$PLUGIN_SRC" ]]; then
        error "Open Wallpaper Engine source directory was not found: $PLUGIN_SRC"
        exit 1
fi

CURRENT_STEP='Building Open Wallpaper Engine plugin'
export PYTHONNOUSERSITE=1

if [[ -n "$CONDA_EXE_PATH" ]]; then
        # Conda's activation scripts are not safe under 'set -u'.
        set +u
        eval "$("$CONDA_EXE_PATH" shell.bash hook)"
        conda activate base
        set -u
else
        warn "Conda not available; building the plugin with the system Python."
fi

cd "$PLUGIN_SRC"

run_with_spinner "Building Open Wallpaper Engine dependencies" \
        lito build --profile release

if [[ ! -d "$PLUGIN_SRC/scripts" ]]; then
        error "Open Wallpaper Engine build scripts were not found."
        exit 1
fi

cd "$PLUGIN_SRC/scripts"

chmod +x build_waywallen_plugin.sh
run_with_spinner "Building Open Wallpaper Engine plugin" \
        ./build_waywallen_plugin.sh

CURRENT_STEP='Copying Open Wallpaper Engine package'

plugin_packages=("$PLUGIN_SRC"/dist/org.waywallen.open-wallpaper-engine*.zip)

if ((${#plugin_packages[@]} == 0)) ||
        [[ ! -f "${plugin_packages[0]}" ]]; then
        error "The plugin build did not produce the expected ZIP package."
        error "Expected: $PLUGIN_SRC/dist/org.waywallen.open-wallpaper-engine*.zip"
        exit 1
fi

PLUGIN_ZIP="$HOME/Downloads/$(basename "${plugin_packages[0]}")"

run_with_spinner "Copying plugin package to Downloads" \
        install -Dm644 "${plugin_packages[0]}" "$PLUGIN_ZIP"

# ------------------------------------------------------------
# Restart KDE Plasma when possible
# ------------------------------------------------------------

CURRENT_STEP='Restarting KDE Plasma'

if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] &&
        [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
        if systemctl --user restart plasma-plasmashell.service; then
                info "KDE Plasma shell restarted."
        else
                warn "Could not restart Plasma automatically."
                warn "Log out and back in if the extension does not appear."
        fi
else
        warn "No active desktop session was detected."
        warn "Restart Plasma manually after installation."
fi

# ------------------------------------------------------------
# Finish
# ------------------------------------------------------------

CURRENT_STEP='Finalizing installation'

info "Plugin package: $PLUGIN_ZIP"
info "Import the ZIP into Waywallen."
info "Restart your system if required."

exit 0