#!/bin/sh
# Stage 1: build the base trixie armhf tarball (all packages) rootlessly. Config comes from the
# environment. Only depends on SUITE/MIRROR/ARCH/KERNEL_CMDLINE, packages and the scripts used here;
# overlays and the like are applied by stage 2 (finish-rootfs.sh).
# usage: build-rootfs.sh OUT.tar
set -eu
out=$1
mkdir -p "$(dirname "$out")" build/apt-cache
pkgs=$(cat packages.txt $( [ -f local/packages.txt ] && echo local/packages.txt ) |
    grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | paste -sd,)

# eatmydata (no fsync) speeds up dpkg a lot; the hook ships with mmdebstrap
eatmydata=/usr/share/mmdebstrap/hooks/eatmydata
set --
[ ! -d "$eatmydata" ] || set -- --hook-directory="$eatmydata"

# Docs are excluded (dpkgopt only applies during the build; copyright files are kept).
# apt's .deb cache lives in build/apt-cache across builds but is not kept in the tarball.
mmdebstrap --mode=unshare --arch="$ARCH" --variant=important --skip=essential/unlink "$@" \
    --dpkgopt='path-exclude=/usr/share/doc/*' \
    --dpkgopt='path-include=/usr/share/doc/*/copyright' \
    --dpkgopt='path-exclude=/usr/share/man/*' \
    --dpkgopt='path-exclude=/usr/share/info/*' \
    --include="$pkgs" \
    --setup-hook='mkdir -p "$1/var/cache/apt/archives"' \
    --setup-hook='sync-in build/apt-cache /var/cache/apt/archives' \
    --essential-hook='scripts/essential.sh "$1"' \
    --customize-hook='sync-out /var/cache/apt/archives build/apt-cache' \
    --customize-hook='rm -rf "$1"/var/cache/apt/archives/*.deb "$1"/var/cache/apt/archives/partial' \
    "$SUITE" "$out" "$MIRROR"
