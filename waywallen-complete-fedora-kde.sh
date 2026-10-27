#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# Waywallen installer for Fedora-based distributions with KDE Plasma.
# Run as a normal desktop user, never as root.

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

WORKDIR=''
CURRENT_STEP='Initialisation'
START_TIME=$SECONDS
SUDO_KEEPALIVE_PID=''
SPINNER_PID=''
INTERRUPTED=0

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

        # Stop any active build before removing its files.
        if [[ -n "$SPINNER_PID" ]]; then
                kill "$SPINNER_PID" 2>/dev/null
                wait "$SPINNER_PID" 2>/dev/null
                SPINNER_PID=''
        fi

        # Stop the sudo credential refresh process.
        if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
                kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
                wait "$SUDO_KEEPALIVE_PID" 2>/dev/null
                SUDO_KEEPALIVE_PID=''
        fi

        # Remove only the temporary directory created by this script.
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

        INTERRUPTED=1
        error "Received $signal; stopping installation."

        # Terminate the active top-level background command.
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

        # Output is saved so failures can display the complete log.
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
# GitHub release and download helpers
# ------------------------------------------------------------

latest_release() {
        local repo=$1
        local response
        local tag

        response=$(curl --proto '=https' --tlsv1.2 \
                -fsSL --retry 3 --retry-delay 2 \
                "https://api.github.com/repos/${repo}/releases/latest")

        tag=$(printf '%s\n' "$response" |
                sed -nE 's/^[[:space:]]*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' |
                head -n 1)

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

# ------------------------------------------------------------
# Preflight checks
# ------------------------------------------------------------

CURRENT_STEP='Preflight checks'

printf '%s\n' \
        "Waywallen installer" \
        "Supported target: Fedora-based Linux with KDE Plasma." \
        "Do not run this script as root."

if ((EUID == 0)); then
        error "Run this script as your normal user, without sudo."
        exit 1
fi

source /etc/os-release
if [[ "$ID" != "fedora" && "$ID_LIKE" != *"fedora"* ]]; then
        error "Fedora was not detected. Aborting."
        exit 1
fi

for cmd in bash curl tar git sudo mktemp sed head; do
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

mkdir -p \
        "$HOME/.local/bin" \
        "$HOME/.local/share/applications" \
        "$HOME/.local/share/locale" \
        "$HOME/Downloads"

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

# ------------------------------------------------------------
# Install Lito
# ------------------------------------------------------------

CURRENT_STEP='Installing Lito'

run_with_spinner "Downloading Lito installer" \
        curl --proto '=https' --tlsv1.2 -fsSL \
        https://lito.litocpp.org/install.sh \
        -o "$WORKDIR/lito-install.sh"

run_with_spinner "Installing Lito" \
        bash "$WORKDIR/lito-install.sh"

if ! command -v lito >/dev/null 2>&1; then
        # Accommodate installers that install into the standard user bin directory.
        if [[ -x "$HOME/.local/bin/lito" ]]; then
                export PATH="$HOME/.local/bin:$PATH"
        else
                error "Lito was not found on PATH after installation."
                exit 1
        fi
fi

# ------------------------------------------------------------
# Install Fedora dependencies
# ------------------------------------------------------------

CURRENT_STEP='Installing Fedora dependencies'

info "Installing required build dependencies"

sudo dnf install -y --skip-unavailable \
        cmake conda gcc gcc-c++ make ninja-build nasm ccache \
        pkgconf-pkg-config pipwire-devel libpipewire-0.3-dev\
        clang clang-tools-extra llvm llvm-devel lld \
        glslang glfw-devel \
        git git-lfs \
        curl gettext \
        rust cargo \
        vulkan-headers vulkan-loader vulkan-loader-devel \
        libglvnd-devel libva libva-devel libva-utils\
        mesa-libGL-devel mesa-libEGL-devel mesa-libGLES-devel mesa-libgbm-devel \
        libdrm-devel libva-utils pipewire-devel\
        pulseaudio-libs-devel pulseaudio-libs freetype-devel expat-devel \
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

run_with_spinner "Configuring Git LFS" git lfs install

if command -v conda >/dev/null 2>&1; then
        if ! grep -q 'conda initialize' "$HOME/.bashrc" 2>/dev/null; then
                run_with_spinner "Initializing Conda for the current user" \
                        bash -c 'conda init; exit 0'
        else
                info "Conda already initialized in ~/.bashrc, skipping."
        fi
else
        warn "Conda was not found; skipping conda init."
fi
# ------------------------------------------------------------
# Download and build Waywallen
# ------------------------------------------------------------

CURRENT_STEP='Downloading Waywallen'

LATEST=$(latest_release waywallen/waywallen)
info "Latest Waywallen release: $LATEST"

run_with_spinner "Downloading Waywallen source" \
        download_archive waywallen/waywallen "$LATEST" \
        "$WORKDIR/waywallen.tar.gz"

run_with_spinner "Extracting Waywallen source" \
        tar -xzf "$WORKDIR/waywallen.tar.gz" -C "$WORKDIR"

WAYWALLEN_SRC="$WORKDIR/waywallen-${LATEST#v}"

if [[ ! -d "$WAYWALLEN_SRC" ]]; then
        error "Waywallen source directory was not found: $WAYWALLEN_SRC"
        exit 1
fi

cd "$WAYWALLEN_SRC"

CURRENT_STEP='Building Waywallen'

run_with_spinner "Building Waywallen (release)" \
        lito build --profile release

CURRENT_STEP='Installing Waywallen'

# Clean up any previous install to avoid stale files.
if [[ -f "$HOME/.local/bin/waywallen" ]]; then
    info "Previous Waywallen installation found; removing before reinstall."
    run_with_spinner "Removing previous Waywallen installation" \
        lito uninstall --prefix "$HOME/.local" --profile release || \
        rm -f \
            "$HOME/.local/bin/waywallen" \
            "$HOME/.local/bin/waywallen-ui" \
            "$HOME/.local/share/icons/hicolor/scalable/apps/org.waywallen.waywallen.svg"
fi

run_with_spinner "Installing Waywallen to ~/.local" \
    lito install --prefix "$HOME/.local" --profile release

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

# Match the release tag and verify the result rather than passing an
# unexpanded wildcard to kpackagetool6.
packages=(build-kde/*.zip)

if ((${#packages[@]} == 0)) || [[ ! -f "${packages[0]}" ]]; then
        error "No Plasma package ZIP was produced."
        error "Check the package filename in build-kde/."
        exit 1
fi

CURRENT_STEP='Installing the KDE Plasma package'

run_with_spinner "Installing the Plasma wallpaper package" \
        kpackagetool6 --type Plasma/Wallpaper \
        --install "${packages[0]}"

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

if [[ ! -d "$PLUGIN_SRC/scripts" ]]; then
        error "Open Wallpaper Engine build scripts were not found."
        exit 1
fi

cd "$PLUGIN_SRC/scripts"

CURRENT_STEP='Building Open Wallpaper Engine plugin'
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

# Successful exit triggers cleanup automatically.
exit 0
