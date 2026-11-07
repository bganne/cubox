include config.mk
-include local/config.mk   # optional local overrides (not shipped on master)
export SUITE MIRROR HOSTNAME TIMEZONE ARCH IMAGE_SIZE BOOT_SIZE BOOT_UUID ROOT_UUID KERNEL_CMDLINE IMAGE
export PATH := $(PATH):/usr/sbin:/sbin

.PHONY: all prereq prereq-check image rootfs check qemu test ssh flash clean FORCE
all: image

prereq:
	HOST_PACKAGES="$(HOST_PACKAGES)" scripts/prereq.sh

prereq-check:
	@missing=; for t in $(HOST_TOOLS); do command -v $$t >/dev/null || missing="$$missing $$t"; done; \
	[ -z "$$missing" ] || { echo "missing host tools:$$missing -- run 'make prereq'" >&2; exit 1; }; \
	grep -q "^$$(id -un):" /etc/subuid /etc/subgid 2>/dev/null || { echo "no subuid/subgid range -- run 'make prereq'" >&2; exit 1; }

# Re-hash all build inputs; only touch the stamp if they changed.
build/inputs.sha: FORCE
	@mkdir -p build
	@{ cat config.mk packages.txt scripts/build-rootfs.sh scripts/customize.sh scripts/mkimage.sh; \
	   find overlay private local -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum; } | sha256sum > $@.new
	@cmp -s $@.new $@ && rm $@.new || mv $@.new $@

rootfs: build/rootfs.tar
build/rootfs.tar: build/inputs.sha | prereq-check
	scripts/build-rootfs.sh $@

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
