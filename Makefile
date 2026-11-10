include config.mk
-include local/config.mk   # optional local overrides (not shipped on master)
export SUITE MIRROR SECURITY_MIRROR HOSTNAME TIMEZONE ARCH IMAGE_SIZE BOOT_SIZE BOOT_UUID ROOT_UUID KERNEL_CMDLINE IMAGE
export PATH := $(PATH):/usr/sbin:/sbin
# pipefail: a failing stage of a pipeline (e.g. an unreadable file in the hashes) fails the recipe
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -ec
# never leave a half-written target that looks up to date
.DELETE_ON_ERROR:

.PHONY: all prereq prereq-check image refresh base rootfs check qemu test ssh flash clean FORCE
all: image

prereq:
	HOST_PACKAGES="$(HOST_PACKAGES)" scripts/prereq.sh

prereq-check:
	@missing=; for t in $(HOST_TOOLS); do command -v $$t >/dev/null || missing="$$missing $$t"; done; \
	[ -z "$$missing" ] || { echo "missing host tools:$$missing -- run 'make prereq'" >&2; exit 1; }; \
	grep -q "^$$(id -un):" /etc/subuid /etc/subgid 2>/dev/null || { echo "no subuid/subgid range -- run 'make prereq'" >&2; exit 1; }

# Two cached stages, each rebuilt only when the hash of its inputs changes:
#   base.tar   packages (slow): suite/mirrors/arch/cmdline, package lists, base scripts.
#              The archive state is not hashed: `make refresh` picks up new (security) updates.
#   rootfs.tar base + customize.sh (fast): config, overlay/, private/, local/
# $(call stamp,FILE,COMMANDS): write the sha256 of COMMANDS' output to FILE only if it changed
stamp = @mkdir -p build; { $(2); } | sha256sum > $(1).new; cmp -s $(1).new $(1) && rm $(1).new || mv $(1).new $(1)

build/base.sha: FORCE
	$(call stamp,$@,echo '$(SUITE) $(MIRROR) $(SECURITY_MIRROR) $(ARCH) $(KERNEL_CMDLINE)'; \
	  cat packages.txt $(wildcard local/packages.txt) scripts/build-base.sh scripts/base-hooks.sh)
build/rootfs.sha: FORCE
	$(call stamp,$@,cat config.mk scripts/build-rootfs.sh scripts/customize.sh scripts/spdif-dtb.sh; \
	  find $(wildcard overlay private local) -printf '%m %l %p\n' | sort; \
	  find $(wildcard overlay private local) -type f -print0 | sort -z | xargs -0 -r sha256sum)

base: build/base.tar
build/base.tar: build/base.sha | prereq-check
	scripts/build-base.sh $@

rootfs: build/rootfs.tar
build/rootfs.tar: build/base.tar build/rootfs.sha | prereq-check
	scripts/build-rootfs.sh build/base.tar $@

image: $(IMAGE)
# Rebuild the base with the current archive state (security updates); run before every flash.
# build/apt-cache is kept, so only changed .debs are downloaded.
refresh:
	rm -f build/base.sha build/base.tar
	$(MAKE) image
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
