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
export CC=musl-gcc
# PKG_CONFIG_PATH adds to the search path, but we want to REPLACE the default search path
# to avoid picking up host libraries (which link against glibc).
export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig:$SYSROOT/lib64/pkgconfig:$SYSROOT/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
# Important: Include sysroot/include to pick up kernel headers
export CFLAGS="-fPIC -I$SYSROOT/include"
export LDFLAGS="-L$SYSROOT/lib -L$SYSROOT/lib64"

# Verify musl include path
echo "Musl include path check:"
$CC -print-search-dirs
exit 0
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
            --prefix="$SYSROOT" \
            --default-library=static \
            -Dwerror=false \
            -Dc_args="$CFLAGS" \
            -Dcpp_args="$CFLAGS" \
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
            CC=musl-gcc \
            "${args[@]}"

        make -j$(nproc)
        
        echo "Installing $name to $SYSROOT..."
        make install
        cd "$PROJECT_ROOT"
    else
        echo "$name already built."
    fi
}

# 0. Dependencies for Wayland
# Libffi
build_autotools "ffi" "libffi"

# Expat
build_autotools "expat" "libexpat/expat"

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

# 1. Wayland (Needs wayland-scanner on host. Meson should handle it if we are careful)
# We might need to build wayland twice: once for host (scanner), once for target.
# For now, let's try standard build.
build_meson "wayland" "wayland" \
    -Ddocumentation=false \
    -Dtests=false \
    -Dlibraries=true

# 2. Wayland Protocols
build_meson "wayland-protocols" "wayland-protocols" \
    -Dtests=false

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
        CC=musl-gcc \
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
if [ ! -f "$SYSROOT/lib/libpython3.13.a" ]; then
    echo "Building Python..."
    
    # 1. Build HOST python first (needed for cross-compilation tools)
    echo "Building host python..."
    build_dir_host="$BUILD_DIR/python-host"
    rm -rf "$build_dir_host"
    mkdir -p "$build_dir_host"
    cp -r "python"/* "$build_dir_host/"
    cd "$build_dir_host"
    ./configure --prefix="$HOST_TOOLS_DIR/python" --without-ensurepip
    make -j$(nproc)
    make install
    
    # Return to project root
    cd "$PROJECT_ROOT"
    
    # 2. Build TARGET python
    echo "Building target python..."
    build_dir="$BUILD_DIR/python"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cp -r "python"/* "$build_dir/"
    cd "$build_dir"
    
    # We need to point to the host python we just built
    # BUT we should NOT export it globally to PATH as it breaks other builds (like Mesa)
    # which expect a full python with packaging/distutils.
    # Only use it for this specific configure call if needed, or trust --with-build-python
    
    # Pre-seed cache variables for cross-compilation
    export ac_cv_file__dev_ptmx=yes
    export ac_cv_file__dev_ptc=no
    
    PATH="$HOST_TOOLS_DIR/python/bin:$PATH" ./configure \
        --prefix="$SYSROOT" \
        --disable-shared \
        --enable-static \
        --host=x86_64-unknown-linux-musl \
        --build=$(./config.guess) \
        --with-build-python="$HOST_TOOLS_DIR/python/bin/python3" \
        --disable-ipv6 \
        --without-ensurepip \
        CC=musl-gcc
        
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
