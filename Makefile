KERNEL_DIR = linux
BUSYBOX_DIR = busybox
INIT_DIR = init_system
BUILD_DIR = build
ROOTFS_DIR = $(BUILD_DIR)/rootfs

.PHONY: all run clean clean-all kernel busybox init submodule-init

all: $(BUILD_DIR)/bzImage $(BUILD_DIR)/initramfs.cpio.gz

# Initialize submodules if they are empty (helper)
submodule-init:
	git submodule update --init --recursive

# Kernel
$(BUILD_DIR)/bzImage:
	mkdir -p $(BUILD_DIR)
	$(MAKE) -C $(KERNEL_DIR) defconfig
	$(MAKE) -C $(KERNEL_DIR) -j$$(nproc) bzImage
	cp $(KERNEL_DIR)/arch/x86/boot/bzImage $@

# Busybox
busybox:
	$(MAKE) -C $(BUSYBOX_DIR) defconfig
	sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' $(BUSYBOX_DIR)/.config
	$(MAKE) -C $(BUSYBOX_DIR) -j$$(nproc)
	mkdir -p $(ROOTFS_DIR)
	$(MAKE) -C $(BUSYBOX_DIR) install CONFIG_PREFIX=$(abspath $(ROOTFS_DIR))

# Init System
init:
	cd $(INIT_DIR) && cargo build --release --target x86_64-unknown-linux-musl
	cp $(INIT_DIR)/target/x86_64-unknown-linux-musl/release/init_system $(ROOTFS_DIR)/init

# Rootfs
$(BUILD_DIR)/initramfs.cpio.gz: busybox init
	mkdir -p $(ROOTFS_DIR)/proc $(ROOTFS_DIR)/sys $(ROOTFS_DIR)/dev $(ROOTFS_DIR)/tmp
	chmod +x $(ROOTFS_DIR)/init
	cd $(ROOTFS_DIR) && find . -print0 | cpio --null -ov --format=newc | gzip > ../initramfs.cpio.gz

run: all
	qemu-system-x86_64 -kernel $(BUILD_DIR)/bzImage -initrd $(BUILD_DIR)/initramfs.cpio.gz -append "console=ttyS0" -nographic

clean:
	rm -rf $(BUILD_DIR)
