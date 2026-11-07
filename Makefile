include config.mk
-include local/config.mk   # optional local overrides (not shipped on master)
export SUITE MIRROR HOSTNAME TIMEZONE ARCH IMAGE_SIZE BOOT_SIZE BOOT_UUID ROOT_UUID KERNEL_CMDLINE IMAGE
export PATH := $(PATH):/usr/sbin:/sbin

.PHONY: all prereq prereq-check image base rootfs check qemu test ssh flash clean FORCE
all: image

prereq:
	HOST_PACKAGES="$(HOST_PACKAGES)" scripts/prereq.sh

prereq-check:
	@missing=; for t in $(HOST_TOOLS); do command -v $$t >/dev/null || missing="$$missing $$t"; done; \
	[ -z "$$missing" ] || { echo "missing host tools:$$missing -- run 'make prereq'" >&2; exit 1; }; \
	grep -q "^$$(id -un):" /etc/subuid /etc/subgid 2>/dev/null || { echo "no subuid/subgid range -- run 'make prereq'" >&2; exit 1; }

# Re-hash build inputs; only touch the stamp if they changed.
# base-inputs.sha: what stage 1 (mmdebstrap -> base.tar) depends on.
build/base-inputs.sha: FORCE
	@mkdir -p build
	@{ printf '%s\n' '$(SUITE)' '$(MIRROR)' '$(ARCH)' '$(KERNEL_CMDLINE)'; \
	   cat packages.txt local/packages.txt scripts/build-rootfs.sh scripts/essential.sh 2>/dev/null; } | sha256sum > $@.new
	@cmp -s $@.new $@ && rm $@.new || mv $@.new $@

# inputs.sha: what stage 2 (base.tar + overlays/customize -> rootfs.tar) depends on.
build/inputs.sha: FORCE
	@mkdir -p build
	@{ cat config.mk packages.txt scripts/build-rootfs.sh scripts/essential.sh scripts/finish-rootfs.sh scripts/customize.sh scripts/mkimage.sh; \
	   find overlay private local -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum; } | sha256sum > $@.new
	@cmp -s $@.new $@ && rm $@.new || mv $@.new $@

# Stage 1 (slow): packages under emulation. apt's .deb cache is kept in build/apt-cache.
base: build/base.tar
build/base.tar: build/base-inputs.sha | prereq-check
	scripts/build-rootfs.sh $@

# Stage 2 (fast): overlays, passwords, initramfs, flash-kernel
rootfs: build/rootfs.tar
build/rootfs.tar: build/base.tar build/inputs.sha scripts/finish-rootfs.sh | prereq-check
	scripts/finish-rootfs.sh build/base.tar $@

image: $(IMAGE)
$(IMAGE): build/rootfs.tar scripts/mkimage.sh | prereq-check
	unshare --map-auto --map-root-user scripts/mkimage.sh build/rootfs.tar $@

check: $(IMAGE)
	scripts/check.sh $(IMAGE) build/rootfs.tar

# qemu virt smoke tests (qcow2 overlay, image untouched)
qemu: $(IMAGE)
	scripts/qemu-test.sh run

test: $(IMAGE)
	scripts/qemu-test.sh test

ssh:
	scripts/qemu-test.sh ssh

# Run with sudo: sudo make flash DEV=/dev/sdX
flash: $(IMAGE)
	scripts/flash.sh "$(DEV)" $(IMAGE)

# Files in build/ may be owned by subuids, so remove them inside a user namespace
clean:
	[ ! -d build ] || unshare --map-auto --map-root-user rm -rf build
