# CuBox Debian 13 image

Rootless Makefile pipeline building an SD image for the CuBox v1 (Dove, vendor U-Boot in SPI flash).

    make prereq                 # once: host packages + subuid range (uses sudo)
    make image                  # build/cubox-trixie.img
    make refresh                # rebuild the package base with today's updates; run before every flash
    make check                  # static checks on the image
    make test                   # boot in qemu (TCG, slow) and run ssh assertions; also reports
                                # packages upgradable since the build
    make qemu                   # interactive serial boot (Ctrl-A X quits); `make ssh` from another terminal
    sudo make flash DEV=/dev/sdX

Layout: p1 ext4 `/boot` (U-Boot reads `boot.scr`, `uImage`, `uInitrd` from its root), p2 f2fs `/`.
On the device `/boot` is an automount (mounted only while dpkg/flash-kernel use it) and `/` is
mounted with `background_gc=off,nodiscard` (weekly fstrim instead) to limit SD card writes.
Generic customizations live in `overlay/` (committed). The network uses DHCP on `eth0`, the
default hostname is `cubox` and the timezone `Etc/UTC` (see `config.mk`).

## Secrets: `private/` (optional, gitignored)

Overlaid last on the rootfs: `etc/ssh/ssh_host_*` host keys and `root.hash` (one-line crypt hash
for root). If `root.hash` is absent the root password is left unchanged (a warning is printed).

## Local layer: `local/` (optional, not shipped on master)

Personal setup lives in a `local/` directory that master supports but does not contain; keep it on a
separate branch rebased onto master. All files are optional:

- `local/config.mk` overrides `config.mk` (HOSTNAME, IMAGE_SIZE, TIMEZONE, KERNEL_CMDLINE, ...)
- `local/packages.txt` extra packages
- `local/overlay/` copied over `overlay/` (before `private/`)
- `local/customize.sh` sourced at the end of the customize stage (scripts/customize.sh) (`$root` = rootfs)
- `local/check.sh` sourced by `scripts/check.sh` (`chk`, `bad`, `ok`, `$tar`)
- `local/qemu-test.sh` sourced by `scripts/qemu-test.sh`: may set `QEMU_NIC`, `EXPECTED_FAILED_RE`
  and define `local_tests` (uses `r`, `pass`, `bad`; must not access `/boot`, whose idle unmount is timed)

`local/` is hashed into `build/rootfs.sha` (and `local/packages.txt` into `build/base.sha`), so
changes trigger a rebuild.

## Kernel updates

Automatic: `flash-kernel` (machine "SolidRun CuBox", set in `/etc/flash-kernel/machine`) hooks into
kernel and initramfs updates and regenerates `/boot/uImage` (zImage + appended DTB), `/boot/uInitrd`
and `/boot/boot.scr`. The kernel command line is `LINUX_KERNEL_CMDLINE` in `/etc/default/flash-kernel`.
`/root/update-kernel.sh` is no longer needed.

flash-kernel keeps the previous files as `uImage.bak`/`uInitrd.bak`. A snippet inserted into the
stock `bootscr.cubox` (`overlay/etc/flash-kernel/ubootenv.d/50-bak-fallback`) checks the CRCs of
`uImage`/`uInitrd` with `iminfo` and boots the `.bak` pair if they are torn or missing (e.g. a power
cut during an update).

If the stock `bootscr.cubox` does not boot with the vendor U-Boot, put the old working script
(with `@@LINUX_KERNEL_CMDLINE@@` placeholders) in `overlay/etc/flash-kernel/bootscript/bootscr.cubox`;
flash-kernel prefers it over its own.

## Updates

The image is built from `trixie`, `trixie-updates` and `trixie-security`. The package base
(`build/base.tar`) is cached and only rebuilt when its inputs change, so run `make refresh` before
flashing to pick up the latest updates. On the device, unattended-upgrades runs nightly at low
CPU/IO priority and reboots at 04:00 when needed.
