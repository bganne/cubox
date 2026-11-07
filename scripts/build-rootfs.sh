#!/bin/sh
# Build the trixie armhf rootfs tarball rootlessly. Config comes from the environment.
# usage: build-rootfs.sh OUT.tar
set -eu
out=$1
mkdir -p "$(dirname "$out")" build/apt-cache
pkgs=$(cat packages.txt $( [ -f local/packages.txt ] && echo local/packages.txt ) |
    grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | paste -sd,)

# private/ is optional (secrets overlay); an empty PRIVATE_TAR means none
PRIVATE_TAR=
[ -d private ] && PRIVATE_TAR=$(tar -C private -c . | base64 -w0)
export PRIVATE_TAR

# eatmydata (no fsync) speeds up dpkg a lot; the hook ships with mmdebstrap
eatmydata=/usr/share/mmdebstrap/hooks/eatmydata
set --
[ ! -d "$eatmydata" ] || set -- --hook-directory="$eatmydata"

# Docs are not installed (copyright files are kept). Downloaded .debs are kept in build/apt-cache
# across builds (synced out before customize.sh runs apt-get clean).
mmdebstrap --mode=unshare --arch="$ARCH" --variant=important --skip=essential/unlink "$@" \
    --dpkgopt='path-exclude=/usr/share/doc/*' \
    --dpkgopt='path-include=/usr/share/doc/*/copyright' \
    --dpkgopt='path-exclude=/usr/share/man/*' \
    --dpkgopt='path-exclude=/usr/share/info/*' \
    --include="$pkgs" \
    --setup-hook='mkdir -p "$1/var/cache/apt/archives"' \
    --setup-hook='sync-in build/apt-cache /var/cache/apt/archives' \
    --essential-hook='scripts/customize.sh essential "$1"' \
    --customize-hook='sync-out /var/cache/apt/archives build/apt-cache' \
    --customize-hook='scripts/customize.sh customize "$1"' \
    "$SUITE" "$out" "$MIRROR"
