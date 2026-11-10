#!/bin/sh
# Stage 2 hook (build-rootfs.sh): overlays, fstab, passwords, local/customize.sh, initramfs and
# flash-kernel, applied on top of build/base.tar. Runs on the host as namespace root.
# usage: customize.sh ROOTFS
set -eu
root=$1

# Overlays: committed first, then local/ (optional), then secrets (optional)
# Not cp -a: the build user is unmapped in this namespace, so preserving ownership would make
# the files (and /, /etc, ... via the overlay's dirs) owned by nobody. New files get root:root;
# existing directories keep their owner and mode.
# Modes are normalized so they don't depend on the host umask or checkout.
ovl() { tar -C "$1" --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w' -c . |
    tar -C "$root" --no-overwrite-dir -x; }
ovl overlay
[ ! -d local/overlay ] || ovl local/overlay
# private/ is not readable by the hook's namespace uid; build-rootfs.sh uploads it as a tarball
# (PRIVATE_TAR = its path inside the rootfs, empty if there is no private/), removed at the end
PRIVATE_TAR=${PRIVATE_TAR:+$root$PRIVATE_TAR}
ptar() { tar -f "$PRIVATE_TAR" "$@"; }
if [ -n "$PRIVATE_TAR" ] && ptar -t | grep -q '^\./etc/'; then
    ptar -x --no-same-owner --no-same-permissions -C "$root" ./etc
fi

cat > "$root/etc/fstab" <<EOT
UUID=$ROOT_UUID	/	f2fs	defaults,noatime,background_gc=off,nodiscard	0	0
UUID=$BOOT_UUID	/boot	ext4	noatime,noauto,nofail,x-systemd.automount,x-systemd.idle-timeout=60	0	2
EOT
# background_gc=off: on a mostly idle box f2fs GC kept compacting segments (~90% of all SD writes);
# foreground GC/SSR still reclaim space when free segments run low.
# nodiscard: no erases issued at each checkpoint (slow and stalling on old SD cards);
# the weekly fstrim.timer trims in one batch instead.
# fsck pass 0 for /: fsck.f2fs refuses a mounted root ("In use by the system", exit 8) and f2fs
# rolls back to its last checkpoint at mount anyway.
# /boot is only touched by dpkg/flash-kernel: mounted on demand, so it is clean (unmounted) at a
# power cut, a failed fsck cannot block the boot, and it is off the boot critical chain.

# apt sources follow SUITE/MIRROR
cat > "$root/etc/apt/sources.list.d/debian.sources" <<EOT
Types: deb
URIs: $MIRROR
Suites: $SUITE $SUITE-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: $SECURITY_MIRROR
Suites: $SUITE-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOT
if [ -n "$PRIVATE_TAR" ] && ptar -t | grep -qx './root.hash'; then
    chroot "$root" usermod -p "$(ptar -xO ./root.hash)" root
else
    echo "WARNING: private/root.hash missing, root password left unchanged" >&2
fi
for k in "$root"/etc/ssh/ssh_host_*_key; do [ ! -e "$k" ] || chmod 600 "$k"; done

echo "$HOSTNAME" > "$root/etc/hostname"
printf '127.0.1.1\t%s\n' "$HOSTNAME" >> "$root/etc/hosts"
chroot "$root" systemctl enable serial-getty@ttyS0.service

# Timezone (locale is set in the base, see base-hooks.sh)
echo "$TIMEZONE" > "$root/etc/timezone"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$root/etc/localtime"

# Optional local hook (see local/ in CLAUDE.md); sourced with $root available
# shellcheck disable=SC1091
[ ! -f local/customize.sh ] || . ./local/customize.sh

# Make sure the kernel cmdline survived debconf, then (re)generate initrd + U-Boot files
if grep -q '^LINUX_KERNEL_CMDLINE=' "$root/etc/default/flash-kernel"; then
    sed -i "s|^LINUX_KERNEL_CMDLINE=.*|LINUX_KERNEL_CMDLINE=\"$KERNEL_CMDLINE\"|" "$root/etc/default/flash-kernel"
else
    echo "LINUX_KERNEL_CMDLINE=\"$KERNEL_CMDLINE\"" >> "$root/etc/default/flash-kernel"
fi
# DTB with the S/PDIF sound card, from the image's (newest) kernel; frozen: flash-kernel appends it
# to every later kernel too
ver=$(chroot "$root" sh -c 'linux-version list | linux-version sort | tail -1')
scripts/spdif-dtb.sh "$root/usr/lib/linux-image-$ver/dove-cubox.dtb" "$root/etc/flash-kernel/dtbs/dove-cubox.dtb"
# The base has no initrd (see base-hooks.sh). Also runs flash-kernel (uImage, uInitrd, boot.scr)
# via /etc/initramfs/post-update.d/flash-kernel
if [ -e "$root/boot/initrd.img-$ver" ]; then op=-u; else op=-c; fi
chroot "$root" update-initramfs "$op" -k "$ver"
# No .bak files from build-time runs: on the device flash-kernel creates them as a consistent
# pair, which boot.scr falls back to (ubootenv.d)
rm -f "$root"/boot/*.bak "$root"/boot/dtbs/*/*.bak

# machine-id is regenerated on first boot
: > "$root/etc/machine-id"
rm -f "$root/var/lib/dbus/machine-id"
[ -z "$PRIVATE_TAR" ] || rm -f "$PRIVATE_TAR"
