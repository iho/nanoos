#!/bin/bash
set -e

# Directories
PROJECT_ROOT="$(pwd)"

BUILD_DIR="$PROJECT_ROOT/build/wayland-deps"
SYSROOT="$PROJECT_ROOT/build/sysroot"
mkdir -p "$BUILD_DIR" "$SYSROOT"

# Safety check: Ensure SYSROOT is within PROJECT_ROOT to avoid accidents
if [[ "$SYSROOT" != "$PROJECT_ROOT"* ]]; then
    echo "Error: SYSROOT must be inside the project root."
    exit 1
fi

# 0. Install Kernel Headers (Required for libffi, etc.)
echo "Installing kernel headers to $SYSROOT..."
make -C linux headers_install INSTALL_HDR_PATH="$SYSROOT"

# 0.5 Build Host Tools (gperf)
HOST_TOOLS_DIR="$PROJECT_ROOT/build/host-tools"
mkdir -p "$HOST_TOOLS_DIR"
export PATH="$HOST_TOOLS_DIR/bin:$PATH"

# 0.6 Setup Musl Toolchain
# Using a specific version for stability (GCC 11.2.1)
TOOLCHAIN_URL="https://more.musl.cc/11.2.1/x86_64-linux-musl/x86_64-linux-musl-cross.tgz"
TOOLCHAIN_DIR="$PROJECT_ROOT/build/toolchain"
TOOLCHAIN_BIN="$TOOLCHAIN_DIR/x86_64-linux-musl-cross/bin"

if [ ! -d "$TOOLCHAIN_DIR" ]; then
    echo "Downloading prebuilt musl toolchain..."
    mkdir -p "$TOOLCHAIN_DIR"
    wget -q --show-progress "$TOOLCHAIN_URL" -O "$TOOLCHAIN_DIR/toolchain.tgz"
    tar -xf "$TOOLCHAIN_DIR/toolchain.tgz" -C "$TOOLCHAIN_DIR"
    rm "$TOOLCHAIN_DIR/toolchain.tgz"
fi

# Add toolchain to PATH
export PATH="$TOOLCHAIN_BIN:$PATH"

if [ ! -f "$HOST_TOOLS_DIR/bin/gperf" ]; then
    echo "Building host gperf..."
    
    # Go to source dir to handle git-based bootstrapping
    cd "$PROJECT_ROOT/gperf"
    
    # Fetch gnulib if needed
    if [ -f gitsub.sh ] && [ ! -d "gnulib" ]; then
        echo "Fetching gnulib for gperf..."
        ./gitsub.sh pull
    fi
    
    # Generate configure script
    if [ ! -f configure ]; then
        if [ -f autogen.sh ]; then
            ./autogen.sh
        else
            autoreconf -ivf
        fi
    fi
    
    if [ ! -f configure ]; then
        echo "Error: gperf bootstrap failed, configure not found."
        exit 1
    fi

    # Build in separate dir
    build_dir="$BUILD_DIR/gperf-host"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cd "$build_dir"
    
    # Build for HOST (standard gcc)
    "$PROJECT_ROOT/gperf/configure" --prefix="$HOST_TOOLS_DIR" CC=gcc
    
    # Build only lib and src to avoid documentation (which needs TeX)
    make -C lib -j$(nproc)
    make -C src -j$(nproc)
    
    # Install only the executable
    make -C src install
    cd "$PROJECT_ROOT"
fi

# Common flags
export CC="x86_64-linux-musl-gcc"
export CXX="x86_64-linux-musl-g++"
export AR="x86_64-linux-musl-ar"
export RANLIB="x86_64-linux-musl-ranlib"

# PKG_CONFIG_PATH adds to the search path, but we want to REPLACE the default search path
# to avoid picking up host libraries (which link against glibc).
export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig:$SYSROOT/lib64/pkgconfig:$SYSROOT/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
# Important: Include sysroot/include to pick up kernel headers
export CFLAGS="-fPIC -I$SYSROOT/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L$SYSROOT/lib -L$SYSROOT/lib64"

# Verify compiler
echo "Compiler check:"
$CC --version

# Function to build meson projects
build_meson() {
    local name=$1
    local src=$2
    local build_dir="$BUILD_DIR/$name"
    shift 2
    local args=("$@")

    if [ ! -f "$SYSROOT/lib/lib$name.a" ] && [ ! -f "$SYSROOT/lib64/lib$name.a" ]; then
        echo "Building $name..."
        
        # Always wipe build directory to ensure clean dependency lookup
        # (Prevents picking up host libs cached from previous runs)
        rm -rf "$build_dir"
        mkdir -p "$build_dir"
        
        meson setup "$build_dir" "$src" \
            --cross-file "$PROJECT_ROOT/cross_musl.txt" \
            --prefix="$SYSROOT" \
            --default-library=static \
            -Dwerror=false \
            -Dc_args="$CFLAGS" \
            -Dcpp_args="$CXXFLAGS" \
            -Dc_link_args="$LDFLAGS" \
            -Dcpp_link_args="$LDFLAGS" \
            "${args[@]}"
        
        echo "Installing $name to $SYSROOT..."
        ninja -C "$build_dir" install
    else
        echo "$name already built."
    fi
}

# Function to build autotools projects
build_autotools() {
    local name=$1
    local src=$2
    local build_dir="$BUILD_DIR/$name"
    shift 2
    local args=("$@")

    if [ ! -f "$SYSROOT/lib/lib$name.a" ] && [ ! -f "$SYSROOT/lib64/lib$name.a" ]; then
        echo "Building $name..."
        rm -rf "$build_dir"
        mkdir -p "$build_dir"
        # Copy source to build dir
        cp -r "$src"/* "$build_dir/"
        cd "$build_dir"
        
        if [ -f autogen.sh ]; then
            ./autogen.sh
        elif [ -f buildconf.sh ]; then
             ./buildconf.sh
        else
            autoreconf -ivf
        fi
        
        # Configure to install ONLY to SYSROOT
        ./configure \
            --prefix="$SYSROOT" \
            --disable-shared \
            --enable-static \
            --host=x86_64-unknown-linux-musl \
            CC="$CC" \
            CXX="$CXX" \
            "${args[@]}"

        make -j$(nproc)
        
        echo "Installing $name to $SYSROOT..."
        make install
        cd "$PROJECT_ROOT"
    else
        echo "$name already built."
    fi
}

# Zlib (Needed by Mesa)
if [ ! -f "$SYSROOT/lib/libz.a" ]; then
    echo "Building zlib..."
    build_dir="$BUILD_DIR/zlib"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cp -r "zlib-source"/* "$build_dir/"
    cd "$build_dir"
    
    CC="$CC" ./configure --prefix="$SYSROOT" --static
    make -j$(nproc)
    make install
    cd "$PROJECT_ROOT"
else
    echo "zlib already built."
fi

# 0. Dependencies for Wayland
# Libffi
build_autotools "ffi" "libffi"

# Expat
build_autotools "expat" "libexpat/expat"

# Ensure freetype/fontconfig submodules have their nested deps
if [ -d "$PROJECT_ROOT/freetype/.git" ]; then
    (cd "$PROJECT_ROOT/freetype" && git submodule update --init --recursive)
fi
if [ -d "$PROJECT_ROOT/fontconfig/.git" ]; then
    (cd "$PROJECT_ROOT/fontconfig" && git submodule update --init --recursive)
fi

# Freetype (needed by fontconfig/alacritty)
build_autotools "freetype" "freetype" \
    --with-bzip2=no \
    --with-harfbuzz=no \
    --with-png=no \
    --with-brotli=no \
    --without-harfbuzz

# Fontconfig (depends on freetype + expat)
build_autotools "fontconfig" "fontconfig" \
    --disable-docs \
    --sysconfdir="$SYSROOT/etc" \
    --localstatedir="$SYSROOT/var" \
    --with-add-fonts=/usr/share/fonts \
    --with-expat="$SYSROOT" \
    --with-freetype-config="$SYSROOT/bin/freetype-config"

# Libxml2 (Wayland often prefers this over expat)
build_autotools "xml2" "libxml2" \
    --without-python \
    --without-zlib \
    --without-lzma \
    --without-debug \
    --without-ftp \
    --without-http \
    --without-legacy \
    --without-history

# Ensure libxml2 headers are accessible via <libxml/...>
if [ -d "$SYSROOT/include/libxml2/libxml" ]; then
    echo "Fixing libxml2 include path..."
    cp -r "$SYSROOT/include/libxml2/libxml" "$SYSROOT/include/"
fi

# Check if headers are installed
if [ ! -f "$SYSROOT/include/ffi.h" ] && [ ! -f "$SYSROOT/lib/libffi-*/include/ffi.h" ]; then
    echo "Error: ffi.h not found in $SYSROOT. Libffi build failed?"
    # Sometimes libffi installs to lib/libffi-X.Y/include
    # We might need to symlink or add to CFLAGS
    find "$SYSROOT" -name ffi.h
    exit 1
fi

if [ ! -f "$SYSROOT/include/expat.h" ]; then
    echo "Error: expat.h not found. Expat build failed?"
    exit 1
fi

# Hack for libffi: It often installs headers in weird places
if [ -d "$SYSROOT"/lib/libffi-*/include ]; then
    echo "Fixing libffi include path..."
    cp -r "$SYSROOT"/lib/libffi-*/include/*.h "$SYSROOT/include/"
fi

# Build a host copy of wayland-scanner (matching the source version) so that
# the cross build can satisfy dependency('wayland-scanner', native: true)
WAYLAND_HOST_PREFIX="$HOST_TOOLS_DIR/wayland"
WAYLAND_HOST_PKGCONFIG="$WAYLAND_HOST_PREFIX/lib/pkgconfig"

if [ ! -x "$WAYLAND_HOST_PREFIX/bin/wayland-scanner" ]; then
    echo "Building host wayland-scanner..."
    host_wayland_build="$BUILD_DIR/wayland-host"
    rm -rf "$host_wayland_build"
    mkdir -p "$host_wayland_build"
    meson setup "$host_wayland_build" "$PROJECT_ROOT/wayland" \
        --prefix="$WAYLAND_HOST_PREFIX" \
        --buildtype=release \
        -Dscanner=true \
        -Ddocumentation=false \
        -Dtests=false \
        -Dlibraries=false
    ninja -C "$host_wayland_build" install
fi

# Copy the host pkg-config entry into the sysroot so cross pkg-config can find it
mkdir -p "$SYSROOT/lib/pkgconfig"
if [ -f "$WAYLAND_HOST_PKGCONFIG/wayland-scanner.pc" ]; then
    cp "$WAYLAND_HOST_PKGCONFIG/wayland-scanner.pc" "$SYSROOT/lib/pkgconfig/"
    sed -i "s|^wayland_scanner=.*|wayland_scanner=$WAYLAND_HOST_PREFIX/bin/wayland-scanner|" "$SYSROOT/lib/pkgconfig/wayland-scanner.pc"
    # PKG_CONFIG_SYSROOT_DIR causes pkg-config to prefix absolute paths with $SYSROOT,
    # so create that path inside the sysroot and symlink to the real host binary.
    scanner_sysroot_path="$SYSROOT$WAYLAND_HOST_PREFIX/bin"
    mkdir -p "$scanner_sysroot_path"
    ln -sf "$WAYLAND_HOST_PREFIX/bin/wayland-scanner" "$scanner_sysroot_path/wayland-scanner"
else
    echo "Error: wayland-scanner.pc not found in host prefix $WAYLAND_HOST_PKGCONFIG" >&2
    exit 1
fi

# 1. Wayland (Needs wayland-scanner on host; .pc above exposes it despite SYSROOT PKG_CONFIG_LIBDIR)
build_meson "wayland" "wayland" \
    -Ddocumentation=false \
    -Dtests=false \
    -Dlibraries=true

# 2. Wayland Protocols
build_meson "wayland-protocols" "wayland-protocols" \
    -Dtests=false

# Some tools read pkg-config variables and then Meson prefixes them with $SYSROOT again,
# so create a mirrored path to avoid "build/sysroot$SYSROOT/..." lookup failures.
if [ -d "$SYSROOT/share/wayland-protocols" ]; then
    mirror_dir="$SYSROOT$SYSROOT/share/wayland-protocols"
    rm -rf "$mirror_dir"
    mkdir -p "$mirror_dir"
    cp -a "$SYSROOT/share/wayland-protocols/." "$mirror_dir/"
fi

# 3. Libdrm
build_meson "drm" "libdrm" \
    -Dintel=disabled \
    -Dradeon=disabled \
    -Damdgpu=disabled \
    -Dnouveau=disabled \
    -Dvmwgfx=disabled \
    -Dfreedreno=disabled \
    -Dvc4=disabled \
    -Detnaviv=disabled \
    -Dvalgrind=disabled \
    -Dman-pages=disabled

# 4. Libevdev
build_meson "evdev" "libevdev" \
    -Dtests=disabled \
    -Ddocumentation=disabled

# Ensure libevdev headers are accessible via <libevdev/...>
if [ -d "$SYSROOT/include/libevdev-1.0/libevdev" ]; then
    echo "Fixing libevdev include path..."
    mkdir -p "$SYSROOT/include/libevdev"
    cp -r "$SYSROOT/include/libevdev-1.0/libevdev"/* "$SYSROOT/include/libevdev/"
fi

# 5. Mtdev
build_autotools "mtdev" "mtdev"

# 6. Eudev (Provides libudev for libinput)
# Eudev needs gperf on host
# Skip autogen.sh because it forces manpage generation which fails
if [ ! -f "$SYSROOT/lib/libudev.a" ]; then
    echo "Building eudev..."
    build_dir="$BUILD_DIR/eudev"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cp -r "eudev"/* "$build_dir/"
    cd "$build_dir"
    autoreconf -ivf
    ./configure \
        --prefix="$SYSROOT" \
        --disable-shared \
        --enable-static \
        --host=x86_64-unknown-linux-musl \
        CC="$CC" \
        --disable-manpages \
        --disable-hwdb \
        --disable-selinux \
        --disable-introspection \
        --disable-tests
    make -j$(nproc)
    make install
    cd "$PROJECT_ROOT"
else
    echo "eudev already built."
fi

# 7. Libinput
# Needs libevdev, mtdev, libudev installed in sysroot
build_meson "input" "libinput" \
    -Ddocumentation=false \
    -Dtests=false \
    -Ddebug-gui=false \
    -Dlibwacom=false

# 8. Seatd
build_meson "seatd" "seatd" \
    -Dserver=enabled \
    -Dlibseat-seatd=enabled \
    -Dlibseat-logind=disabled \
    -Dlibseat-builtin=enabled \
    -Dman-pages=disabled \
    -Dexamples=disabled

# 9. Libxkbcommon
build_meson "xkbcommon" "libxkbcommon" \
    -Denable-wayland=true \
    -Denable-x11=false \
    -Denable-docs=false

# 10. Pixman
build_meson "pixman" "pixman" \
    -Dtests=disabled \
    -Dgtk=disabled

# 11. Python (Static)
# We strictly require CPython 3.13.x for PyO3 compatibility. The repository
# ships a python submodule; ensure it is checked out to a 3.13 release.
PYTHON_MAJOR_MINOR="3.13"
PYTHON_SRC_DIR="$PROJECT_ROOT/python"
PYTHON_HOST_PREFIX="$HOST_TOOLS_DIR/python-$PYTHON_MAJOR_MINOR"
PY_PATCHLEVEL_FILE="$PYTHON_SRC_DIR/Include/patchlevel.h"

assert_python_submodule_version() {
    if [ ! -d "$PYTHON_SRC_DIR" ]; then
        echo "Error: python submodule missing at $PYTHON_SRC_DIR. Run 'git submodule update --init python'." >&2
        exit 1
    fi
    if [ ! -f "$PY_PATCHLEVEL_FILE" ]; then
        echo "Error: $PY_PATCHLEVEL_FILE not found; python submodule appears incomplete." >&2
        exit 1
    fi
    if ! grep -q 'PY_MINOR_VERSION[[:space:]]\+13' "$PY_PATCHLEVEL_FILE"; then
        echo "Error: python submodule is not on a 3.13 release. Please checkout v3.13.x within the submodule." >&2
        exit 1
    fi
}

if [ ! -f "$SYSROOT/lib/libpython${PYTHON_MAJOR_MINOR}.a" ]; then
    assert_python_submodule_version
    echo "Building Python $(grep -m1 'PY_VERSION' "$PY_PATCHLEVEL_FILE" | tr -d '\"' | awk '{print $3}')..."

    echo "Removing any previously installed Python versions from sysroot..."
    for path in "$SYSROOT"/lib/python3.*; do
        if [ -e "$path" ]; then
            rm -rf "$path"
        fi
    done
    rm -f "$SYSROOT"/lib/libpython3.*.a
    rm -rf "$SYSROOT"/include/python3.*

    # 1. Build HOST python first (needed for cross-compilation tools)
    echo "Building host python..."
    build_dir_host="$BUILD_DIR/python-host"
    rm -rf "$build_dir_host"
    mkdir -p "$build_dir_host"
    cp -a "$PYTHON_SRC_DIR"/. "$build_dir_host/"
    cd "$build_dir_host"
    ./configure --prefix="$PYTHON_HOST_PREFIX" --without-ensurepip
    make -j$(nproc)
    make install

    # Return to project root
    cd "$PROJECT_ROOT"

    # 2. Build TARGET python
    echo "Building target python..."
    build_dir="$BUILD_DIR/python"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cp -a "$PYTHON_SRC_DIR"/. "$build_dir/"
    cd "$build_dir"

    # Pre-seed cache variables for cross-compilation
    export ac_cv_file__dev_ptmx=yes
    export ac_cv_file__dev_ptc=no

    # Use the host python we just built
    HOST_PYTHON="$PYTHON_HOST_PREFIX/bin/python3"

    PATH="$PYTHON_HOST_PREFIX/bin:$PATH" ./configure \
        --prefix="$SYSROOT" \
        --disable-shared \
        --enable-static \
        --host=x86_64-unknown-linux-musl \
        --build=$(./config.guess) \
        --with-build-python="$HOST_PYTHON" \
        --disable-ipv6 \
        --without-ensurepip \
        CC="$CC" \
        CXX="$CXX"

    make -j$(nproc)
    make install
    cd "$PROJECT_ROOT"
else
    echo "Python already built."
fi

# 11.5 Setup Python Dependencies for Mesa (Mako, PyYAML)
# Mesa requires Mako and PyYAML. We use submodules for these.
# Mako depends on MarkupSafe.
export PYTHONPATH="$PROJECT_ROOT/MarkupSafe/src:$PROJECT_ROOT/Mako:$PROJECT_ROOT/PyYAML/lib:$PROJECT_ROOT/ply:$PYTHONPATH"

# 12. Mesa (libgbm, libEGL, libglapi)
# Minimal build for VirtIO-GPU (virgl) and Software Rasterizer (softpipe)
# LLVM disabled to keep it tiny (uses softpipe instead of llvmpipe)
# Note: swrast is not a valid gallium driver name in modern mesa, use softpipe or llvmpipe
build_meson "mesa" "mesa" \
    -Dgallium-drivers=softpipe,virgl \
    -Dvulkan-drivers=[] \
    -Dplatforms=wayland \
    -Dgbm=enabled \
    -Degl=enabled \
    -Dgles1=disabled \
    -Dgles2=enabled \
    -Dglx=disabled \
    -Dllvm=disabled \
    -Dmicrosoft-clc=disabled \
    -Dvalgrind=disabled \
    -Dlibunwind=disabled \
    -Dandroid-libbacktrace=disabled \
    -Dlmsensors=disabled \
    -Dbuild-tests=false

echo "Wayland dependencies built in $SYSROOT"
