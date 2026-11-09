# Build configuration (exported to the scripts by the Makefile)
SUITE = trixie
MIRROR = http://deb.debian.org/debian
HOSTNAME = cubox
TIMEZONE = Etc/UTC
ARCH = armhf
# Image size in bytes (multiple of 512); match your SD card or leave small and grow later
IMAGE_SIZE = 2147483648
BOOT_SIZE = 200M
BOOT_UUID = d7d99cb1-bb1f-4ad1-aa1b-dc386834e7f7
ROOT_UUID = ba4142c6-6081-41af-ab18-07bfbf1c334d
KERNEL_CMDLINE = root=UUID=$(ROOT_UUID) rootfstype=f2fs rootwait net.ifnames=0
IMAGE = build/cubox-trixie.img
HOST_PACKAGES = mmdebstrap qemu-user-binfmt qemu-user qemu-system-arm qemu-utils uidmap f2fs-tools e2fsprogs fdisk u-boot-tools arch-test initramfs-tools-core zstd device-tree-compiler
HOST_TOOLS = mmdebstrap sload.f2fs mkfs.f2fs qemu-arm mkimage dumpimage newuidmap sfdisk debugfs mke2fs lsinitramfs fdtput fdtget dtc
