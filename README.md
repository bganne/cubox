# CuBox Debian 13 image

Rootless Makefile pipeline building an SD image for the CuBox v1 (Dove, vendor U-Boot in SPI flash).

    make prereq                 # once: host packages + subuid range (uses sudo)
    make image                  # build/cubox-trixie.img
    make check                  # static checks on the image
    make test                   # boot in qemu (TCG, slow) and run ssh assertions
    make qemu                   # interactive serial boot (Ctrl-A X quits); `make ssh` from another terminal
    sudo make flash DEV=/dev/sdX

Layout: p1 ext4 `/boot` (U-Boot reads `boot.scr`, `uImage`, `uInitrd` from its root), p2 f2fs `/`.
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
  and define `local_tests` (uses `r`, `pass`, `bad`)

`local/` is part of the `build/inputs.sha` hash, so changes trigger a rebuild.

## Kernel updates

Automatic: `flash-kernel` (machine "SolidRun CuBox", set in `/etc/flash-kernel/machine`) hooks into
kernel and initramfs updates and regenerates `/boot/uImage` (zImage + appended DTB), `/boot/uInitrd`
and `/boot/boot.scr`. The kernel command line is `LINUX_KERNEL_CMDLINE` in `/etc/default/flash-kernel`.
`/root/update-kernel.sh` is no longer needed.

If the stock `bootscr.cubox` does not boot with the vendor U-Boot, put the old working script
(with `@@LINUX_KERNEL_CMDLINE@@` placeholders) in `overlay/etc/flash-kernel/bootscript/bootscr.cubox`;
flash-kernel prefers it over its own.
