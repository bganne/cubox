#!/bin/sh
# Stage 2: apply overlays and customizations (customize.sh) on top of the base tarball (fast).
# usage: build-rootfs.sh BASE.tar OUT.tar
set -eu
base=$1
out=$2

# private/ is optional (secrets overlay). The hooks run as an unmapped subuid that cannot read it, so
# it goes in as a tarball via mmdebstrap's upload (read as the invoking user); customize.sh deletes it.
# PRIVATE_TAR is its path inside the rootfs, empty means no private/.
set --
PRIVATE_TAR=
if [ -d private ]; then
    ptar=$(mktemp build/private.XXXXXX.tar)   # mode 600
    trap 'rm -f "$ptar"' EXIT
    tar -C private -cf "$ptar" .
    PRIVATE_TAR=/tmp/private.tar
    set -- --customize-hook="upload $ptar $PRIVATE_TAR"
fi
export PRIVATE_TAR

# Reuse the base tarball as the chroot (see mmdebstrap(1) EXAMPLES): no apt setup/update/cleanup
mmdebstrap --mode=unshare --arch="$ARCH" --variant=custom \
    --skip=update,setup,cleanup,tar-in/mknod \
    --setup-hook="tar-in $base /" \
    "$@" \
    --customize-hook='scripts/customize.sh "$1"' \
    '' "$out"
