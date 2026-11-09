#!/bin/sh
# mmdebstrap hooks for the base stage (build-base.sh), run on the host as namespace root; $2 = rootfs.
# Only things that do not depend on overlay/private/local belong here (changes rebuild the base).
# usage: base-hooks.sh essential|customize ROOTFS
set -eu
stage=$1
root=$2

case $stage in
essential)
    # Must be in place before the kernel is installed so flash-kernel's hooks work in the chroot
    mkdir -p "$root/etc/flash-kernel"
    echo "SolidRun CuBox" > "$root/etc/flash-kernel/machine"
    # the build host may be EFI; this makes flash-kernel skip otherwise
    echo yes > "$root/etc/flash-kernel/ignore-efi"
    echo "flash-kernel flash-kernel/linux_cmdline string $KERNEL_CMDLINE" |
        chroot "$root" debconf-set-selections
    ;;
customize)
    sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' "$root/etc/locale.gen"
    chroot "$root" locale-gen
    echo 'LANG=en_US.UTF-8' > "$root/etc/default/locale"
    rm -f "$root/etc/apt/sources.list"
    # cron (from the important variant) wakes up every minute; its jobs all have systemd timers
    chroot "$root" dpkg --purge cron cron-daemon-common
    # e2scrub only works on LVM; nothing writes to pstore on this board
    chroot "$root" systemctl mask e2scrub_all.timer e2scrub_reap.service systemd-pstore.service
    ;;
*)
    echo "unknown stage $stage" >&2; exit 1 ;;
esac
