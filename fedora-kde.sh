#!/usr/bin/bash
echo "This script is only meant for systems running Fedora based distros with KDE plasma as the DE.\nPlease do not use on arch/debian/nix based systems."

error() {
        echo -e "${RED}[ERROR]${NC} $1" >&2
}

warn() {
        echo -e "${YELLOW}[WARN]${NC} $1"
}

info() {
        echo -e "${GREEN}[INFO]${NC} $1"
}

spinner() {
        local pid=$1
        local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        while kill -0 "$pid" 2>/dev/null; do
                for i in $(seq 0 9); do
                        printf "\r${frames:$i:1} Installing..."
                        sleep 0.1
                done
        done
        printf "\rDone!          \n"
}

# download and install lito
info "Downloading and installing lito"
curl --proto '=https' --tlsv1.2 -sSf https://lito.litocpp.org/install.sh | sh &
spinner $!

# install fedora dependencies
info "Installing dependencies for build"

sudo dnf install --skip-unavailable \
        cmake conda gcc gcc-c++ make ninja-build nasm ccache \
        pkgconf-pkg-config \
        clang clang-tools-extra llvm llvm-devel lld \
        glslang glfw-devel \
        git git-lfs \
        curl gettext \
        rust cargo \
        vulkan-headers vulkan-loader vulkan-loader-devel \
        libglvnd-devel \
        mesa-libGL-devel mesa-libEGL-devel mesa-libGLES-devel mesa-libgbm-devel \
        libdrm-devel libva-utils \
        freetype-devel expat-devel \
        lz4-devel zlib-ng-compat-devel \
        wayland-devel wayland-protocols-devel \
        libX11-devel libXcomposite-devel libXdamage-devel \
        libXext-devel libXfixes-devel libXrandr-devel libXrender-devel \
        libXScrnSaver-devel libxcb-devel libxkbcommon-devel \
        alsa-lib-devel gtk3-devel nss-devel \
        gbm protobuf-compiler \
        qt6-qtbase-devel \
        qt6-qtdeclarative-devel \
        qt6-qtwebsockets-devel \
        qt6-qttools-devel \
        qt6-qtgrpc-devel \
        qt6-qtshadertools-devel \
        ffmpeg-free-devel libdav1d-devel \
        plasma-workspace kpackagetool6

git lfs install
conda init

# download waywallen tarball and extract then cd to directory

info "Downloading and extracting waywallen"
LATEST=$(curl -fsSL https://api.github.com/repos/waywallen/waywallen/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
curl -fsSL "https://github.com/waywallen/waywallen/archive/refs/tags/${LATEST}.tar.gz" -o waywallen.tar.gz
tar -xzf waywallen.tar.gz
cd waywallen-${LATEST#v}

# build and install using lito
info "Building and installing waywallen for current user"
lito build --profile release
lito install --prefix "$HOME/.local" --profile release
export PATH="$HOME/.local/bin:$PATH"
export QML_IMPORT_PATH="$HOME/.local/lib/qt6/qml"
export LD_LIBRARY_PATH="$HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

#modify the desktop entry bekos broken image otherwise :<

rm /home/kokonut/.local/share/applications/org.waywallen.waywallen.desktop

cat >"$HOME/.local/bin/waywallen-start" <<'EOF'
#!/bin/sh

export PATH="$HOME/.local/bin:$PATH"
export QML_IMPORT_PATH="$HOME/.local/lib/qt6/qml"
export LD_LIBRARY_PATH="$HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

exec "$HOME/.local/bin/waywallen" \
    --ui "$HOME/.local/bin/waywallen-ui" \
    --plugin "$HOME/.local/share/waywallen"
EOF

chmod +x "$HOME/.local/bin/waywallen-start"

cat >$HOME/.local/share/applications/org.waywallen.waywallen.desktop <<EOF
[Desktop Entry]
Categories=Graphics;Qt;
Comment[en_US]=Wallpaper Manager for Linux
Comment=Wallpaper Manager for Linux
Comment[de]=Hintergrundbildverwaltung für Linux
Comment[ru]=Менеджер обоев для Linux
Exec=$HOME/.local/bin/waywallen-start
GenericName[en_US]=Wallpaper Manager for Linux
GenericName=Wallpaper Manager for Linux
GenericName[de]=Hintergrundbildverwaltung für Linux
GenericName[ru]=Менеджер обоев для Linux
Icon=$HOME/.local/share/icons/hicolor/scalable/apps/org.waywallen.waywallen.svg
Keywords=wallpaper;pipewire;vulkan;
Keywords[de]=Hintergrundbild;Hintergrund;Live-Hintergrund;Arbeitsfläche;wallpaper;pipewire;vulkan;
Keywords[ru]=обои;живые обои;рабочий стол;wallpaper;pipewire;vulkan;
MimeType=
Name[en_US]=Waywallen
Name=Waywallen
Path=
StartupNotify=true
Terminal=false
TerminalOptions=
Type=Application
X-KDE-SubstituteUID=false
X-KDE-Username=
EOF

# Now waywallen is installed, building and installing waywallen-display

info "Downloading waywallen-bridge for KDE"
cd $HOME

# https://github.com/waywallen/waywallen-display/releases/tag/v0.4.3
LATEST_DISPLAY=$(curl -fsSL https://api.github.com/repos/waywallen/waywallen-display/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
curl -fsSL "https://github.com/waywallen/waywallen-display/archive/refs/tags/${LATEST_DISPLAY}}.tar.gz" -o waywallen-display.tar.gz
tar -xzf waywallen-display.tar.gz
cd waywallen-display-${LATEST_DISPLAY#v}

info "Installing waywallen-display...."

cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr

cmake --build build -j"$(nproc)"

sudo cmake --install build

sudo ldconfig

cargo build --release

install -Dm755 \
        target/release/waywallen-layer-shell \
        ~/.local/bin/waywallen-layer-shell
mkdir -p ~/.local/share/locale
for po in po/layer-shell/*.po; do
        lang="$(basename "$po" .po)"
        install -Dm644 \
                <(msgfmt "$po") \
                "$HOME/.local/share/locale/$lang/LC_MESSAGES/waywallen-layer-shell.mo"
done

cmake --build build --target waywallen-layer-shell-translations
#plasma extension
cmake -S . -B build-kde \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DWAYWALLEN_DISPLAY_PLUGIN_QML=ON \
        -DWAYWALLEN_DISPLAY_WITH_VULKAN=ON

cmake --build build-kde -j"$(nproc)"
cmake --build build-kde --target package

kpackagetool6 --type Plasma/Wallpaper \
        --install build-kde/waywallen-kde-${LATEST_DISPLAY}-*.zip

#system-wide
sudo cmake --install build-kde
sudo ldconfig
systemctl --user restart plasma-plasmashell.service

#open-wallpaper-engine plugin
cd $HOME
info "Downloading and building wallpaper engine plugin"
PLUGIN=$(curl -fsSL https://api.github.com/repos/waywallen/open-wallpaper-engine/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
curl -fsSL "https://github.com/waywallen/open-wallpaper-engine/archive/refs/tags/${PLUGIN}.tar.gz" -o open-wallpaper-engine.tar.gz
tar -xzf open-wallpaper-engine.tar.gz
cd open-wallpaper-engine-${PLUGIN#v}/scripts
export PYTHONNOUSERSITE=1
conda activate base
bash build_waywallen_plugin.sh

cp $HOME/open-wallpaper-engine-${PLUGIN#v}/dist/org.waywallen.open-wallpaper-engine*.zip $HOME/Downloads

info "Cleaning up.."

rm -rf $HOME/open-wallpaper-engine-${PLUGIN#v}
rm -rf $HOME/waywallen-display-${LATEST_DISPLAY#v}
rm -rf $HOME/waywallen-${LATEST#v}

info "Import org.waywallen.open-wallpaper-engine zip file from downloads into waywallen, and restart your system."
