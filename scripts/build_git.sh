#!/bin/bash
set -e

# Directory where dependencies will be downloaded and built
BUILD_DIR="$(pwd)/build/deps"
mkdir -p "$BUILD_DIR"

# Source directories (git submodules)
PROJECT_ROOT="$(pwd)"
ZLIB_SRC="$PROJECT_ROOT/zlib-source"
GIT_SRC="$PROJECT_ROOT/git-source"

# Target directory for the git binary
INSTALL_DIR="$1"
if [ -z "$INSTALL_DIR" ]; then
    echo "Usage: $0 <install_dir>"
    exit 1
fi

# --- Zlib ---
echo "Preparing zlib..."
if [ ! -d "$ZLIB_SRC" ]; then
    echo "Error: zlib-source submodule not found!"
    exit 1
fi

# Copy source to build dir to avoid polluting the submodule
rm -rf "$BUILD_DIR/zlib"
cp -r "$ZLIB_SRC" "$BUILD_DIR/zlib"
cd "$BUILD_DIR/zlib"

echo "Building zlib..."
CC=musl-gcc ./configure --static
make -j$(nproc)

# --- Git ---
echo "Preparing git..."
if [ ! -d "$GIT_SRC" ]; then
    echo "Error: git-source submodule not found!"
    exit 1
fi

# Copy source to build dir
rm -rf "$BUILD_DIR/git"
cp -r "$GIT_SRC" "$BUILD_DIR/git"
cd "$BUILD_DIR/git"

echo "Building git..."
# Compile Git statically with minimal features
# musl doesn't support REG_STARTEND, so we need NO_REGEX=NeedsStartEnd
make -j$(nproc) \
    CC=musl-gcc \
    CFLAGS="-static -I$BUILD_DIR/zlib" \
    LDFLAGS="-static -L$BUILD_DIR/zlib" \
    NO_OPENSSL=YesPlease \
    NO_CURL=YesPlease \
    NO_EXPAT=YesPlease \
    NO_PERL=YesPlease \
    NO_PYTHON=YesPlease \
    NO_TCLTK=YesPlease \
    NO_GETTEXT=YesPlease \
    NO_ICONV=YesPlease \
    NO_INSTALL_HARDLINKS=YesPlease \
    NO_REGEX=NeedsStartEnd \
    NO_SECURE_MEMORY=YesPlease \
    git

echo "Installing git to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cp git "$INSTALL_DIR/git"

echo "Done!"
