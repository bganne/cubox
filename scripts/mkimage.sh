#!/bin/sh
# Assemble the SD image from the rootfs tarball. Must run inside a user namespace:
#   unshare --map-auto --map-root-user scripts/mkimage.sh ROOTFS.tar OUT.img
set -eu
tar=$1
out=$2
work=build/mkimage.tmp
rm -rf "$work"; mkdir -p "$work/rootfs"
trap 'rm -rf "$work"' EXIT

tar --numeric-owner --xattrs --exclude='./dev/*' -xpf "$tar" -C "$work/rootfs"

# Layout: p1 ext4 /boot at sector 2048, p2 f2fs root takes the rest
total=$((IMAGE_SIZE / 512))
p1start=2048
p1size=$(( ${BOOT_SIZE%M} * 2048 ))
p2start=$((p1start + p1size))
p2size=$((total - p2start))

# /boot goes to p1; p2 gets an empty mount point
mv "$work/rootfs/boot" "$work/bootfs"
mkdir "$work/rootfs/boot"

truncate -s $((p1size * 512)) "$work/boot.img"
mke2fs -q -t ext4 -U "$BOOT_UUID" -d "$work/bootfs" "$work/boot.img"

truncate -s $((p2size * 512)) "$work/root.img"
mkfs.f2fs -q -f -U "$ROOT_UUID" "$work/root.img"
sload.f2fs -P -f "$work/rootfs" "$work/root.img"

rm -f "$out"
truncate -s "$IMAGE_SIZE" "$out"
sfdisk -q "$out" <<EOT
label: dos
start=$p1start, size=$p1size, type=83
start=$p2start, size=$p2size, type=83
EOT
dd if="$work/boot.img" of="$out" bs=512 seek=$p1start conv=notrunc status=none
dd if="$work/root.img" of="$out" bs=512 seek=$p2start conv=notrunc status=none
echo "image: $out"
