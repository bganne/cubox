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
ovl() { tar -C "$1" --owner=0 --group=0 --numeric-owner -c . | tar -C "$root" --no-overwrite-dir -x; }
ovl overlay
[ ! -d local/overlay ] || ovl local/overlay
# private/ is not readable by the hook's namespace uid; build-rootfs.sh passes it as PRIVATE_TAR
ptar() { printf %s "$PRIVATE_TAR" | base64 -d | tar "$@"; }
if [ -n "$PRIVATE_TAR" ] && ptar -t | grep -q '^\./etc/'; then
    ptar -x --no-same-owner --no-same-permissions -C "$root" ./etc
fi

cat > "$root/etc/fstab" <<EOT
UUID=$ROOT_UUID	/	f2fs	defaults	0	1
UUID=$BOOT_UUID	/boot	ext4	defaults	0	2
EOT
if [ -n "$PRIVATE_TAR" ] && ptar -t | grep -qx './root.hash'; then
    chroot "$root" usermod -p "$(ptar -xO ./root.hash)" root
else
    echo "WARNING: private/root.hash missing, root password left unchanged" >&2
fi
for k in "$root"/etc/ssh/ssh_host_*_key; do [ ! -e "$k" ] || chmod 600 "$k"; done

echo "$HOSTNAME" > "$root/etc/hostname"
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
chroot "$root" update-initramfs -u -k all
chroot "$root" flash-kernel

# machine-id is regenerated on first boot
: > "$root/etc/machine-id"
rm -f "$root/var/lib/dbus/machine-id"
