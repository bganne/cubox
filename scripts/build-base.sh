#!/bin/sh
# Stage 1: install packages into a rootless armhf base tarball (slow; rebuilt only when the
# suite, mirror, kernel cmdline, package lists or base scripts change). Config from the environment.
# usage: build-base.sh OUT.tar
set -eu
out=$1
mkdir -p "$(dirname "$out")" build/apt-cache
pkgs=$(cat packages.txt $( [ -f local/packages.txt ] && echo local/packages.txt ) |
    grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | paste -sd,)

# eatmydata (no fsync) speeds up dpkg a lot; the hook ships with mmdebstrap
eatmydata=/usr/share/mmdebstrap/hooks/eatmydata
set --
[ ! -d "$eatmydata" ] || set -- --hook-directory="$eatmydata"

# Docs are not installed (copyright files are kept). Downloaded .debs are kept in build/apt-cache
# across builds; mmdebstrap's cleanup then empties the cache and lists inside the tarball.
mmdebstrap --mode=unshare --arch="$ARCH" --variant=important --skip=essential/unlink "$@" \
    --dpkgopt='path-exclude=/usr/share/doc/*' \
    --dpkgopt='path-include=/usr/share/doc/*/copyright' \
    --dpkgopt='path-exclude=/usr/share/man/*' \
    --dpkgopt='path-exclude=/usr/share/info/*' \
    --include="$pkgs" \
    --setup-hook='mkdir -p "$1/var/cache/apt/archives"' \
    --setup-hook='sync-in build/apt-cache /var/cache/apt/archives' \
    --essential-hook='scripts/base-hooks.sh essential "$1"' \
    --customize-hook='sync-out /var/cache/apt/archives build/apt-cache' \
    --customize-hook='scripts/base-hooks.sh customize "$1"' \
    "$SUITE" "$out" "$MIRROR"
