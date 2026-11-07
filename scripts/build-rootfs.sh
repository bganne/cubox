#!/bin/sh
# Stage 2: apply overlays and customizations (customize.sh) on top of the base tarball (fast).
# usage: build-rootfs.sh BASE.tar OUT.tar
set -eu
base=$1
out=$2

# private/ is optional (secrets overlay); an empty PRIVATE_TAR means none
PRIVATE_TAR=
[ -d private ] && PRIVATE_TAR=$(tar -C private -c . | base64 -w0)
export PRIVATE_TAR

# Reuse the base tarball as the chroot (see mmdebstrap(1) EXAMPLES): no apt setup/update/cleanup
mmdebstrap --mode=unshare --arch="$ARCH" --variant=custom \
    --skip=update,setup,cleanup,tar-in/mknod \
    --setup-hook="tar-in $base /" \
    --customize-hook='scripts/customize.sh "$1"' \
    '' "$out"
