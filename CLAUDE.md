# CuBox v1 Debian 13 armhf image builder

Rootless Makefile pipeline -> SD image (p1 ext4 /boot without extents for the old U-Boot, p2 f2fs /). Kernel updates are handled
on the device by flash-kernel (machine "SolidRun CuBox").

## Branches
`master` = generic builder (DHCP on eth0, hostname cubox, UTC). Personal setup lives on branch `htpc`,
which only adds files under `local/` (see below) and is rebased onto master. Never put personal
settings in master files; extend the `local/` hooks instead.

## Layout
- `Makefile`, `config.mk` (suite, mirror, sizes, fixed BOOT/ROOT UUIDs, TIMEZONE, kernel cmdline, HOST_PACKAGES/HOST_TOOLS)
- `packages.txt` one package per line
- `scripts/build-base.sh` stage 1: mmdebstrap (unshare mode, armhf via qemu-user, eatmydata hook, no docs/man,
  .deb cache in build/apt-cache) + `scripts/base-hooks.sh` (flash-kernel machine/debconf, locale) -> build/base.tar
- `scripts/build-rootfs.sh` stage 2: mmdebstrap `--variant=custom` on top of base.tar running
  `scripts/customize.sh` (overlay, fstab, apt sources, passwords, local hook, initramfs, flash-kernel) -> build/rootfs.tar.
  private/ is uploaded as a tarball ($PRIVATE_TAR, deleted at the end), base-hooks.sh purges cron
- `scripts/mkimage.sh` run under `unshare --map-auto --map-root-user`: partitions + mke2fs/mkfs.f2fs/sload.f2fs
- `scripts/check.sh` static image checks; `scripts/prereq.sh`; `scripts/flash.sh`; `scripts/diag.sh` on-device diagnostics (diag-*.txt gitignored)
- `scripts/qemu-test.sh run|test|ssh`: qemu virt boot of a qcow2 overlay (build/qemu/), ssh via systemd credential key
- `overlay/` committed files copied into the rootfs; `private/` gitignored secrets overlay (optional)

## local/ layer (optional, absent on master; all files optional)
- `local/config.mk` (`-include`d after config.mk), `local/packages.txt` (appended), `local/overlay/` (after overlay/, before private/)
- `local/customize.sh` sourced by customize.sh ($root, $PRIVATE_TAR = private tarball path, `ptar` = tar -f it)
- `local/check.sh` sourced by check.sh (chk/bad/ok, $tar); `local/qemu-test.sh` sourced by qemu-test.sh
  (set QEMU_NIC, EXPECTED_FAILED_RE; define `local_tests` using r/pass/bad)
- `local/` is hashed into build/rootfs.sha (`local/packages.txt` also into build/base.sha)

## Targets
`make prereq` (sudo, idempotent), `image`, `check`, `qemu` (interactive, Ctrl-A X), `test` (automated, slow: TCG; `TEST_APT=1` adds an apt freshness report), `ssh` (into running qemu, port 2222),
`base`, `rootfs`, `refresh` (rebuild base.tar with current archive updates; run before every flash), `sudo make flash DEV=/dev/sdX`,
`clean` (rm inside userns: build/ has subuid-owned files). Build is rootless; only prereq and flash need root.
`make prereq`: HOST_PACKAGES in config.mk + subuid/subgid range for $USER. `prereq-check` verifies HOST_TOOLS.

## private/ contents (gitignored, optional, never print)
`etc/ssh/ssh_host_*` keys, `root.hash` (crypt hash, one line; absent = root unchanged + warning). Extra files go under `etc/`.

## Notes
- Config vars are exported by the Makefile to scripts; scripts read them from the environment.
- `net.ifnames=0` keeps the NIC `eth0`. Default qemu test net is user-mode (guest DHCP 10.0.2.15, ssh via host port 2222).
- Two cached stages: build/base.tar rebuilds when build/base.sha (SUITE/MIRROR/SECURITY_MIRROR/ARCH/KERNEL_CMDLINE, package lists,
  build-base.sh, base-hooks.sh) changes; build/rootfs.tar when base.tar or build/rootfs.sha (config.mk, build-rootfs.sh, spdif-dtb.sh,
  customize.sh, overlay, private, local incl. modes/symlinks) changes. Anything needing no overlay/private/local input goes in
  base-hooks.sh. Base = SUITE + -updates + -security; archive state is not hashed (hence `make refresh`). The base has
  no initrd/U-Boot files (update-initramfs and flash-kernel stubbed by base-hooks.sh); customize.sh creates them.
  `make clean` also drops build/apt-cache. Makefile uses bash + pipefail and .DELETE_ON_ERROR.
- Initramfs is MODULES=list (overlay/etc/initramfs-tools/{conf.d,modules}), hwdb.bin dropped by hooks/zz-prune-hwdb; check.sh verifies the SD/virtio/f2fs modules.
- boot.scr: overlay/etc/flash-kernel/ubootenv.d/50-bak-fallback boots uImage.bak/uInitrd.bak when the CRCs fail (iminfo);
  customize.sh deletes the build-time .bak files. apt-daily-upgrade.service runs Nice=19/idle IO (lowprio.conf).
- fstab: / f2fs `background_gc=off,nodiscard` (weekly fstrim.timer); /boot automount (noauto,nofail,idle-timeout). f2fs made with inode/sb checksums.
- Internal S/PDIF: customize.sh runs `scripts/spdif-dtb.sh` (host fdtput) once on the image kernel's dove-cubox.dtb (adds a
  simple-audio-card on audio1 DAI 1) into /etc/flash-kernel/dtbs/, frozen for later kernels; ALSA card `CuBoxSPDIF`.
