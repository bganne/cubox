#!/bin/sh
# Stage-2 customization (run by finish-rootfs.sh on the host as namespace root).
# usage: customize.sh ROOTFS
set -eu
root=$1

# Overlays: committed first, then local/ (optional), then secrets (optional)
cp -a overlay/. "$root"/
[ ! -d local/overlay ] || cp -a local/overlay/. "$root"/
# private/ is passed as PRIVATE_TAR (set by finish-rootfs.sh)
ptar() { printf %s "$PRIVATE_TAR" | base64 -d | tar "$@"; }
if [ -n "$PRIVATE_TAR" ] && ptar -t | grep -q '^\./etc/'; then
    ptar -x --no-same-owner --no-same-permissions -C "$root" ./etc
fi
rm -f "$root/etc/apt/sources.list"

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

# Locale and timezone
sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' "$root/etc/locale.gen"
chroot "$root" locale-gen
echo 'LANG=en_US.UTF-8' > "$root/etc/default/locale"
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
# Drop the no-op stubs that scripts/essential.sh diverted in, so the installed system is normal
for cmd in /usr/sbin/update-initramfs /usr/sbin/flash-kernel; do
    rm -f "$root$cmd"
    chroot "$root" dpkg-divert --local --rename --remove "$cmd"
done
for d in "$root"/lib/modules/*/; do
    v=$(basename "$d")
    if [ -e "$root/boot/initrd.img-$v" ]; then m=-u; else m=-c; fi
    chroot "$root" update-initramfs $m -k "$v"
done
# flash-kernel runs from /etc/initramfs/post-update.d/flash-kernel after each update-initramfs

# Cleanup; machine-id is regenerated on first boot
chroot "$root" apt-get clean
rm -rf "$root"/var/lib/apt/lists/*
: > "$root/etc/machine-id"
rm -f "$root/var/lib/dbus/machine-id"
