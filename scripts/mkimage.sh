#!/bin/sh
# Assemble the SD image from the rootfs tarball. Must run inside a user namespace:
#   unshare --map-auto --map-root-user scripts/mkimage.sh ROOTFS.tar OUT.img
set -eu
tar=$1
out=$2
work=build/mkimage.tmp
rm -rf "$work"; mkdir -p "$work/rootfs"
trap 'rm -rf "$work" "$out.tmp"' EXIT

tar --numeric-owner --xattrs --exclude='./dev/*' -xpf "$tar" -C "$work/rootfs"

# Layout: p1 ext4 /boot at sector 2048, at least BOOT_SIZE, ending on a 4 MiB boundary so that
# p2 (f2fs root, the rest) is aligned to the SD card's allocation units and f2fs's 2 MiB segments.
total=$((IMAGE_SIZE / 512))
p1start=2048
align=8192
p2start=$(( (p1start + ${BOOT_SIZE%M} * 2048 + align - 1) / align * align ))
p1size=$((p2start - p1start))
p2size=$((total - p2start))

# /boot goes to p1; p2 gets an empty mount point
mv "$work/rootfs/boot" "$work/bootfs"
mkdir "$work/rootfs/boot"

truncate -s $((p1size * 512)) "$work/boot.img"
# No extents: the 2009 Marvell U-Boot cannot read files whose extent tree has depth > 0
# (e.g. a fragmented uInitrd rewritten by flash-kernel). 64bit requires extents.
# -m 0: no blocks reserved for root, only root writes there anyway.
mke2fs -q -t ext4 -m 0 -O ^extent,^64bit -U "$BOOT_UUID" -d "$work/bootfs" "$work/boot.img"

truncate -s $((p2size * 512)) "$work/root.img"
# Checksums detect torn inode/superblock writes after a power cut; lost_found for fsck.f2fs.
# No flexible_inline_xattr: sload.f2fs 1.16 writes inodes inconsistent with it
mkfs.f2fs -q -f -l root -O extra_attr,inode_checksum,sb_checksum,lost_found \
    -U "$ROOT_UUID" "$work/root.img"
sload.f2fs -P -f "$work/rootfs" "$work/root.img"

# Written to $tmp, renamed at the end: an interrupted run leaves no complete-looking image
tmp=$out.tmp
rm -f "$tmp"
truncate -s "$IMAGE_SIZE" "$tmp"
sfdisk -q "$tmp" <<EOT
label: dos
start=$p1start, size=$p1size, type=83
start=$p2start, size=$p2size, type=83
EOT
dd if="$work/boot.img" of="$tmp" bs=512 seek=$p1start conv=notrunc status=none
dd if="$work/root.img" of="$tmp" bs=512 seek=$p2start conv=notrunc status=none
mv "$tmp" "$out"
echo "image: $out"
