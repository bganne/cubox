#!/bin/sh
# mmdebstrap essential hook, run on the host as namespace root; $1 = rootfs.
# Everything here feeds build/base.tar (see base-inputs.sha in the Makefile).
set -eu
root=$1

# Must be in place before the kernel is installed so flash-kernel's hooks work in the chroot
mkdir -p "$root/etc/flash-kernel"
echo "SolidRun CuBox" > "$root/etc/flash-kernel/machine"
# the build host may be EFI; this makes flash-kernel skip otherwise
echo yes > "$root/etc/flash-kernel/ignore-efi"
echo "flash-kernel flash-kernel/linux_cmdline string $KERNEL_CMDLINE" |
    chroot "$root" debconf-set-selections

# Skip update-initramfs and flash-kernel while packages are installed: divert them to a no-op
# stub. The customize stage (scripts/customize.sh) removes the diversions and runs both once.
for cmd in /usr/sbin/update-initramfs /usr/sbin/flash-kernel; do
    chroot "$root" dpkg-divert --local --rename --divert "$cmd.real" --add "$cmd"
    printf '#!/bin/sh\nexit 0\n' > "$root$cmd"
    chmod 755 "$root$cmd"
done
