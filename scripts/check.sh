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
dump=$(sfdisk -d "$img")
part() { echo "$dump" | sed -n "s/^.*$1 *: *start= *\([0-9]*\), *size= *\([0-9]*\), *type=83.*/\1 \2/p"; }
read -r p1start p1size <<EOF
$(part 1)
EOF
read -r p2start p2size <<EOF
$(part 2)
EOF
: "${p1start:=0}" "${p1size:=0}" "${p2start:=1}" "${p2size:=0}"
chk "p1 layout (sector 2048, >= BOOT_SIZE)" test "$p1start" -eq 2048 -a "$p1size" -ge $(( ${BOOT_SIZE%M} * 2048 ))
chk "p2 layout (follows p1, 4 MiB aligned, to the end)" test "$p2start" -eq $((p1start + p1size)) \
    -a $((p2start % 8192)) -eq 0 -a $((p2start + p2size)) -eq "$total"

dd if="$img" of="$work/boot.img" bs=512 skip="$p1start" count="$p1size" status=none
ls=$(debugfs -R 'ls -p /' "$work/boot.img" 2>/dev/null)
chk "p1 has no extent feature (old U-Boot)" sh -c "debugfs -R stats '$work/boot.img' 2>/dev/null | grep '^Filesystem features:' | grep -vqw extent"
for f in boot.scr uImage uInitrd 'vmlinuz-' 'initrd\.img-'; do
    chk "p1 contains $f" sh -c "echo '$ls' | grep -q '/$f'"
done
chk "/boot has no .bak files (stale from the build)" sh -c "! tar -tf '$tar' | grep -q '^\./boot/.*\.bak\$'"
chk "p1 has no reserved blocks" sh -c "debugfs -R stats '$work/boot.img' 2>/dev/null | grep -Eq '^Reserved block count: +0\$'"
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
chk "boot.scr falls back to uImage.bak/uInitrd.bak" sh -c "grep -aq 'prefix}uImage\.bak;' '$work/boot.scr' && grep -aq 'prefix}uInitrd\.bak;' '$work/boot.scr'"
# root on SD (CuBox: sdhci-dove + deps; mmc_block/mmc_core are built into armmp) and on virtio in qemu.
# A near-empty initrd must fail here.
lsinitramfs "$work/initrd" > "$work/initrd.ls"
for m in f2fs crc32_generic sdhci-dove sdhci-pltfm sdhci virtio_blk; do
    chk "initramfs has $m.ko" grep -q "/$m\.ko" "$work/initrd.ls"
done
# MODULES=list (overlay/etc/initramfs-tools/conf.d): a handful of modules, not MODULES=most's ~800
chk "initramfs has < 50 modules (MODULES=list)" sh -c "[ \$(grep -c '\.ko' '$work/initrd.ls') -lt 50 ]"
chk "initramfs has no udev hwdb.bin (hooks/zz-prune-hwdb)" sh -c "! grep -q 'hwdb\.bin\$' '$work/initrd.ls'"

# Rootfs content (from the tarball)
# overlays must not leak the (unmapped) build user as nobody (65534) into the image
chk "no files owned by nobody" sh -c "! tar -tvf '$tar' | awk '\$2 ~ /^65534\\// {print; f=1} END {exit !f}'"
for f in etc/fstab etc/flash-kernel/machine etc/apt/apt.conf.d/20auto-upgrades usr/bin/unattended-upgrade \
         usr/lib/systemd/system-shutdown/cubox-gpu-power etc/systemd/system.conf.d/watchdog.conf \
         etc/systemd/system/apt-daily-upgrade.service.d/lowprio.conf etc/flash-kernel/ubootenv.d/50-bak-fallback; do
    chk "rootfs has $f" sh -c "tar -tf '$tar' | grep -qx './$f'"
done
tar -xOf "$tar" ./etc/fstab > "$work/fstab"
chk "fstab: / has background_gc=off" grep -Eq '^UUID=[^ 	]+[ 	]+/[ 	].*background_gc=off' "$work/fstab"
chk "fstab: / has nodiscard" grep -Eq '^UUID=[^ 	]+[ 	]+/[ 	].*nodiscard' "$work/fstab"
chk "fstab: / has fsck pass 0" grep -Eq '^UUID=[^ 	]+[ 	]+/[ 	].*[ 	]0[ 	]+0$' "$work/fstab"
chk "fstrim.timer enabled" sh -c "tar -tf '$tar' | grep -q '^./etc/systemd/system/timers.target.wants/fstrim.timer$'"
chk "fstab: /boot is an automount" grep -Eq '^UUID=[^ 	]+[ 	]+/boot[ 	].*noauto,nofail,x-systemd\.automount' "$work/fstab"
chk "apt sources use SUITE=$SUITE" sh -c "tar -xOf '$tar' ./etc/apt/sources.list.d/debian.sources | grep -q '^Suites: $SUITE-security'"
chk "/etc/hosts has 127.0.1.1 $HOSTNAME" sh -c "tar -xOf '$tar' ./etc/hosts | grep -Eq '^127\.0\.1\.1[[:space:]]+$HOSTNAME\$'"
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
