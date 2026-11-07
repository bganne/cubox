# CuBox v1 Debian 13 armhf image builder

Rootless Makefile pipeline -> SD image (p1 ext4 /boot, p2 f2fs /). Kernel updates are handled
on the device by flash-kernel (machine "SolidRun CuBox"). Design: ~/.claude/plans/i-have-an-old-fluttering-frost.md

## Branches
`master` = generic builder (DHCP on eth0, hostname cubox, UTC). Personal setup lives on branch `htpc`,
which only adds files under `local/` (see below) and is rebased onto master. Never put personal
settings in master files; extend the `local/` hooks instead.

## Layout
- `Makefile`, `config.mk` (suite, mirror, sizes, fixed BOOT/ROOT UUIDs, TIMEZONE, kernel cmdline, HOST_PACKAGES/HOST_TOOLS)
- `packages.txt` one package per line
- `scripts/build-rootfs.sh` mmdebstrap (unshare mode, armhf via qemu-user) -> build/rootfs.tar
- `scripts/customize.sh` mmdebstrap essential/customize hooks (overlay, fstab, passwords, initramfs, flash-kernel)
- `scripts/mkimage.sh` run under `unshare --map-auto --map-root-user`: partitions + mke2fs/mkfs.f2fs/sload.f2fs
- `scripts/check.sh` static image checks; `scripts/prereq.sh`; `scripts/flash.sh`
- `scripts/qemu-test.sh run|test|ssh`: qemu virt boot of a qcow2 overlay (build/qemu/), ssh via systemd credential key
- `overlay/` committed files copied into the rootfs; `private/` gitignored secrets overlay (optional)

## local/ layer (optional, absent on master; all files optional)
- `local/config.mk` (`-include`d after config.mk), `local/packages.txt` (appended), `local/overlay/` (after overlay/, before private/)
- `local/customize.sh` sourced at end of customize stage ($root, $PRIVATE_TAR, `ptar`)
- `local/check.sh` sourced by check.sh (chk/bad/ok, $tar); `local/qemu-test.sh` sourced by qemu-test.sh
  (set QEMU_NIC, EXPECTED_FAILED_RE; define `local_tests` using r/pass/bad)
- `local/` is hashed into build/inputs.sha

## Targets
`make prereq` (sudo, idempotent), `image`, `check`, `qemu` (interactive, Ctrl-A X), `test` (automated, slow: TCG), `ssh` (into running qemu, port 2222),
`sudo make flash DEV=/dev/sdX`, `clean` (rm inside userns: build/ has subuid-owned files).
Build is rootless; only prereq and flash need root.

## Host prerequisites
`make prereq`: HOST_PACKAGES in config.mk + subuid/subgid range for $USER. `prereq-check` verifies HOST_TOOLS.

## private/ contents (gitignored, optional, never print)
`etc/ssh/ssh_host_*` keys, `root.hash` (crypt hash, one line; absent = root unchanged + warning). Extra files go under `etc/`.

## Notes
- Config vars are exported by the Makefile to scripts; scripts read them from the environment.
- `net.ifnames=0` keeps the NIC `eth0`. Default qemu test net is user-mode (guest DHCP 10.0.2.15, ssh via host port 2222).
- build/rootfs.tar rebuilds when build/inputs.sha (hash of config, packages, scripts, overlay, private, local) changes.
