#!/bin/sh
# Static checks on the image, no root needed.
# usage: check.sh IMAGE ROOTFS.tar   (config via environment)
set -eu
img=$1
tar=$2
work=build/check.tmp
rm -rf "$work"; mkdir -p "$work"
trap 'rm -rf "$work"' EXIT
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
chk() { d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

total=$((IMAGE_SIZE / 512))
p1size=$(( ${BOOT_SIZE%M} * 2048 ))
p2start=$((2048 + p1size))
p2size=$((total - p2start))

dump=$(sfdisk -d "$img")
chk "p1 layout" sh -c "echo '$dump' | grep -q 'start= *2048, size= *$p1size, type=83'"
chk "p2 layout" sh -c "echo '$dump' | grep -q 'start= *$p2start, size= *$p2size, type=83'"

dd if="$img" of="$work/boot.img" bs=512 skip=2048 count=$p1size status=none
ls=$(debugfs -R 'ls -p /' "$work/boot.img" 2>/dev/null)
for f in boot.scr uImage uInitrd 'vmlinuz-6\.12' 'initrd\.img-6\.12'; do
    chk "p1 contains $f" sh -c "echo '$ls' | grep -q '/$f'"
done
for f in boot.scr uImage; do
    debugfs -R "dump /$f $work/$f" "$work/boot.img" 2>/dev/null
done
initrd=$(echo "$ls" | tr '/' '\n' | grep '^initrd\.img-6\.12' | head -1)
debugfs -R "dump /$initrd $work/initrd" "$work/boot.img" 2>/dev/null

chk "mkimage -l uImage" mkimage -l "$work/uImage"
info=$(dumpimage -l "$work/uImage" 2>&1 || true)
chk "kernel load address 0x8000" sh -c "echo '$info' | grep -Eiq 'Load Address: 0*8000\$'"
chk "kernel entry point 0x8000" sh -c "echo '$info' | grep -Eiq 'Entry Point: *0*8000\$'"

dtb=$(tar -tf "$tar" | grep 'linux-image-6\.12.*/dove-cubox\.dtb$' | head -1)
if [ -n "$dtb" ]; then
    tar -xOf "$tar" "$dtb" > "$work/dove-cubox.dtb"
    n=$(stat -c %s "$work/dove-cubox.dtb")
    tail -c "$n" "$work/uImage" > "$work/uimage-tail"
    chk "uImage ends with dove-cubox.dtb" cmp "$work/uimage-tail" "$work/dove-cubox.dtb"
else
    bad "dove-cubox.dtb not found in rootfs"
fi

chk "boot.scr has root=UUID=$ROOT_UUID" grep -aq "root=UUID=$ROOT_UUID" "$work/boot.scr"
chk "boot.scr has net.ifnames=0" grep -aq 'net.ifnames=0' "$work/boot.scr"
# root on SD (CuBox: sdhci-dove + deps; mmc_block/mmc_core are built into armmp) and on virtio in qemu.
# A near-empty initrd must fail here.
for m in f2fs sdhci-dove sdhci-pltfm sdhci virtio_blk; do
    chk "initramfs has $m.ko" sh -c "lsinitramfs '$work/initrd' | grep -q '/$m\.ko'"
done

# Rootfs content (from the tarball)
# overlays must not leak the (unmapped) build user as nobody (65534) into the image
chk "no files owned by nobody" sh -c "! tar -tvf '$tar' | awk '\$2 ~ /^65534\\// {print; f=1} END {exit !f}'"
for f in etc/fstab etc/flash-kernel/machine; do
    chk "rootfs has $f" sh -c "tar -tf '$tar' | grep -qx './$f'"
done
for k in private/etc/ssh/ssh_host_*_key; do
    [ -e "$k" ] || continue
    f=etc/ssh/$(basename "$k")
    chk "rootfs has $f" sh -c "tar -tf '$tar' | grep -qx './$f'"
done

# Optional local checks (can use chk/bad/ok, $tar, $img, $work)
# shellcheck disable=SC1091
[ ! -f local/check.sh ] || . ./local/check.sh

[ $fail -eq 0 ] && echo "all checks passed" || { echo "CHECKS FAILED"; exit 1; }
