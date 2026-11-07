#!/bin/sh
# Stage 2: base.tar + overlays/customization -> rootfs.tar, without re-running mmdebstrap.
# usage: finish-rootfs.sh BASE.tar OUT.tar
# Re-executes itself in a user namespace (subuid range mapped, like mmdebstrap's unshare mode),
# unpacks the base into a scratch dir, runs scripts/customize.sh in a chroot with /proc /sys /dev,
# and repacks with numeric owners (as mkimage.sh reads it).
set -eu
if [ "${FINISH_IN_NS:-}" != 1 ]; then
    FINISH_IN_NS=1 exec unshare --map-auto --map-root-user --mount --pid --fork --kill-child "$0" "$@"
fi
base=$1
out=$2
root=build/finish.tmp
# Host /dev and /sys are never bound wholesale: a stray rm -rf must not reach host files.
devs="null zero full random urandom tty"
umount_all() {
    for d in $devs; do umount "$root/dev/$d" 2>/dev/null || true; done
    for m in dev proc; do umount "$root/$m" 2>/dev/null || true; done
}
safe_rm() {  # refuse to delete while anything is still mounted below $root
    [ -d "$root" ] || return 0
    if awk -v r="$(realpath "$root")/" 'index($5, r) == 1 { found=1 } END { exit !found }' /proc/self/mountinfo; then
        echo "finish-rootfs: mounts left under $root, not removing it" >&2; return 1
    fi
    rm -rf --one-file-system "$root"
}
cleanup() { umount_all; safe_rm; }
safe_rm; mkdir -p "$root"
trap cleanup EXIT

# private/ is optional (secrets overlay); an empty PRIVATE_TAR means none
PRIVATE_TAR=
[ -d private ] && PRIVATE_TAR=$(tar -C private -c . | base64 -w0)
export PRIVATE_TAR
# like mmdebstrap: never block on stdin (flash_kernel_set_root asks for Enter when the root UUID is absent)
export DEBIAN_FRONTEND=noninteractive

tar --numeric-owner --xattrs --exclude='./dev/*' -xpf "$base" -C "$root"
mount -t proc proc "$root/proc"
mount -t tmpfs -o mode=755 tmpfs "$root/dev"
for d in $devs; do : > "$root/dev/$d"; mount --bind "/dev/$d" "$root/dev/$d"; done
ln -s /proc/self/fd "$root/dev/fd"
scripts/customize.sh "$root"
umount_all

tar --numeric-owner --xattrs --sort=name --exclude='./dev/*' --exclude='./sys/*' --exclude='./proc/*' -cpf "$out.tmp" -C "$root" .
mv "$out.tmp" "$out"
