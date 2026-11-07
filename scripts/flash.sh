#!/bin/sh
# Write the image to an SD card. Run as root: sudo make flash DEV=/dev/sdX
set -eu
dev=${1:-}; img=$2
[ -n "$dev" ] || { echo "usage: make flash DEV=/dev/sdX" >&2; exit 1; }
[ -b "$dev" ] || { echo "$dev is not a block device" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
name=$(basename "$(readlink -f "$dev")")
if grep -q "^/dev/$name" /proc/mounts; then echo "$dev has mounted partitions" >&2; exit 1; fi
case $name in
    mmcblk*) ;;
    *) [ "$(cat "/sys/block/$name/removable" 2>/dev/null)" = 1 ] ||
        { echo "$dev is not removable" >&2; exit 1; } ;;
esac
printf 'Write %s to %s (ALL DATA LOST)? [y/N] ' "$img" "$dev"
read -r a; [ "$a" = y ] || exit 1
# O_DIRECT bypasses the page cache so the progress reflects what reached the card
dd if="$img" of="$dev" bs=4M oflag=direct conv=fsync status=progress
sync
