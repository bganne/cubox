#!/bin/sh
# Build the trixie armhf rootfs tarball rootlessly. Config comes from the environment.
# usage: build-rootfs.sh OUT.tar
set -eu
out=$1
mkdir -p "$(dirname "$out")"
pkgs=$(cat packages.txt $( [ -f local/packages.txt ] && echo local/packages.txt ) |
    grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | paste -sd,)

# private/ is optional (secrets overlay); an empty PRIVATE_TAR means none
PRIVATE_TAR=
[ -d private ] && PRIVATE_TAR=$(tar -C private -c . | base64 -w0)
export PRIVATE_TAR

mmdebstrap --mode=unshare --arch="$ARCH" --variant=important \
    --include="$pkgs" \
    --essential-hook='scripts/customize.sh essential "$1"' \
    --customize-hook='scripts/customize.sh customize "$1"' \
    "$SUITE" "$out" "$MIRROR"
