#!/bin/bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$PWD/build/ostree-repo}"
IMAGES_DIR="${IMAGES_DIR:-$PWD/buildroot/output/images}"
BRANCH="${BRANCH:-nanoos/stable/x86_64}"
VERSION="${VERSION:-$(date -u +%Y%m%d%H%M%S)}"

ROOTFS_TAR="$IMAGES_DIR/nanoos-rootfs.tar"

if [ ! -f "$ROOTFS_TAR" ]; then
    echo "Rootfs tarball not found at $ROOTFS_TAR. Run 'make buildroot' first." >&2
    exit 1
fi

mkdir -p "$REPO_DIR"
ostree --repo "$REPO_DIR" init --mode=archive-z2 >/dev/null 2>&1 || true

echo "Committing $ROOTFS_TAR into $BRANCH (version $VERSION)..."
ostree --repo "$REPO_DIR" commit \
    --branch "$BRANCH" \
    --tree=tar="$ROOTFS_TAR" \
    --add-metadata-string version="$VERSION" \
    --subject "NanoOS $VERSION ($(git rev-parse --short HEAD))"

ostree --repo "$REPO_DIR" summary --update
echo "OSTree commit completed. Repo: $REPO_DIR"
