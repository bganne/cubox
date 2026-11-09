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
chk "p1 has no extent feature (old U-Boot)" sh -c "debugfs -R stats '$work/boot.img' 2>/dev/null | grep '^Filesystem features:' | grep -vqw extent"
for f in boot.scr uImage uInitrd 'vmlinuz-' 'initrd\.img-'; do
    chk "p1 contains $f" sh -c "echo '$ls' | grep -q '/$f'"
done
for f in boot.scr uImage; do
    debugfs -R "dump /$f $work/$f" "$work/boot.img" 2>/dev/null
done
initrd=$(echo "$ls" | tr '/' '\n' | grep '^initrd\.img-' | sort -V | tail -1)
debugfs -R "dump /$initrd $work/initrd" "$work/boot.img" 2>/dev/null

chk "mkimage -l uImage" mkimage -l "$work/uImage"
info=$(dumpimage -l "$work/uImage" 2>&1 || true)
chk "kernel load address 0x8000" sh -c "echo '$info' | grep -Eiq 'Load Address: 0*8000\$'"
chk "kernel entry point 0x8000" sh -c "echo '$info' | grep -Eiq 'Entry Point: *0*8000\$'"

dtb=./etc/flash-kernel/dtbs/dove-cubox.dtb
if tar -tf "$tar" | grep -qx "$dtb"; then
    tar -xOf "$tar" "$dtb" > "$work/dove-cubox.dtb"
    n=$(stat -c %s "$work/dove-cubox.dtb")
    tail -c "$n" "$work/uImage" > "$work/uimage-tail"
    chk "uImage ends with patched dove-cubox.dtb" cmp "$work/uimage-tail" "$work/dove-cubox.dtb"
    chk "dove-cubox.dtb has the S/PDIF sound card" grep -aq 'simple-audio-card' "$work/dove-cubox.dtb"
else
    bad "patched $dtb not found in rootfs (scripts/spdif-dtb.sh)"
fi

chk "boot.scr has root=UUID=$ROOT_UUID" grep -aq "root=UUID=$ROOT_UUID" "$work/boot.scr"
chk "boot.scr has net.ifnames=0" grep -aq 'net.ifnames=0' "$work/boot.scr"
# root on SD (CuBox: sdhci-dove + deps; mmc_block/mmc_core are built into armmp) and on virtio in qemu.
# A near-empty initrd must fail here.
lsinitramfs "$work/initrd" > "$work/initrd.ls"
for m in f2fs crc32_generic sdhci-dove sdhci-pltfm sdhci virtio_blk; do
    chk "initramfs has $m.ko" grep -q "/$m\.ko" "$work/initrd.ls"
done
# MODULES=list (overlay/etc/initramfs-tools/conf.d): a handful of modules, not MODULES=most's ~800
chk "initramfs has < 50 modules (MODULES=list)" sh -c "[ \$(grep -c '\.ko' '$work/initrd.ls') -lt 50 ]"

# Rootfs content (from the tarball)
# overlays must not leak the (unmapped) build user as nobody (65534) into the image
chk "no files owned by nobody" sh -c "! tar -tvf '$tar' | awk '\$2 ~ /^65534\\// {print; f=1} END {exit !f}'"
for f in etc/fstab etc/flash-kernel/machine etc/apt/apt.conf.d/20auto-upgrades usr/bin/unattended-upgrade usr/lib/systemd/system-shutdown/cubox-gpu-power etc/systemd/system.conf.d/watchdog.conf; do
    chk "rootfs has $f" sh -c "tar -tf '$tar' | grep -qx './$f'"
done
tar -xOf "$tar" ./etc/fstab > "$work/fstab"
chk "fstab: / has background_gc=off" grep -Eq '^UUID=[^ 	]+[ 	]+/[ 	].*background_gc=off' "$work/fstab"
chk "fstab: /boot is an automount" grep -Eq '^UUID=[^ 	]+[ 	]+/boot[ 	].*noauto,nofail,x-systemd\.automount' "$work/fstab"
chk "apt sources use SUITE=$SUITE" sh -c "tar -xOf '$tar' ./etc/apt/sources.list.d/debian.sources | grep -q '^Suites: $SUITE-security'"
chk "cron is not installed" sh -c "! tar -tf '$tar' | grep -qx './usr/sbin/cron'"
chk "no private tarball left in the rootfs" sh -c "! tar -tf '$tar' | grep -qx './tmp/private.tar'"
for k in private/etc/ssh/ssh_host_*_key; do
    [ -e "$k" ] || continue
    f=etc/ssh/$(basename "$k")
    chk "rootfs has $f" sh -c "tar -tf '$tar' | grep -qx './$f'"
done

# Optional local checks (can use chk/bad/ok, $tar, $img, $work)
# shellcheck disable=SC1091
[ ! -f local/check.sh ] || . ./local/check.sh

[ $fail -eq 0 ] && echo "all checks passed" || { echo "CHECKS FAILED"; exit 1; }
