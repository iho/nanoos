KERNEL_DIR = linux
BUSYBOX_DIR = busybox
INIT_DIR = init_system
NUSHELL_DIR = nushell
BUILD_DIR = build
ROOTFS_DIR = $(BUILD_DIR)/rootfs

.PHONY: all run clean clean-all kernel busybox init nushell submodule-init

all: $(BUILD_DIR)/bzImage $(BUILD_DIR)/initramfs.cpio.gz

# Initialize submodules if they are empty (helper)
submodule-init:
	git submodule update --init --recursive

# Kernel
$(BUILD_DIR)/bzImage:
	mkdir -p $(BUILD_DIR)
	$(MAKE) -C $(KERNEL_DIR) LLVM=1 tinyconfig
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_64BIT
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_TTY
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_PRINTK
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_BINFMT_ELF
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_PCI
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_SERIAL_8250
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_SERIAL_8250_CONSOLE
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_BINFMT_SCRIPT
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_BLK_DEV_INITRD
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_PROC_FS
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_SYSFS
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_DEVTMPFS
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_DEVTMPFS_MOUNT
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_FILE_LOCKING
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_EPOLL
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_SIGNALFD
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_TIMERFD
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_EVENTFD
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_SHMEM
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_INOTIFY_USER
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_FANOTIFY
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_FUTEX
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_NET
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_UNIX
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_INET
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_PACKET
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_NETDEVICES
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_ETHERNET
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_NET_VENDOR_INTEL
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_E1000
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_NET_VENDOR_NATSEMI
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_VIRTIO
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_VIRTIO_MENU
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_VIRTIO_NET
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_VIRTIO_PCI
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_VIRTIO_PCI_LEGACY
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_ACPI
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_PCI_MSI
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_DRM
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_DRM_VIRTIO_GPU
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_INPUT_EVDEV
	$(MAKE) -C $(KERNEL_DIR) LLVM=1 olddefconfig                                 
	$(MAKE) -C $(KERNEL_DIR) LLVM=1 -j$$(nproc) bzImage                          
	cp $(KERNEL_DIR)/arch/x86/boot/bzImage $@ 

# Busybox
$(ROOTFS_DIR)/bin/busybox:
	$(MAKE) -C $(BUSYBOX_DIR) defconfig
	sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' $(BUSYBOX_DIR)/.config
	sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' $(BUSYBOX_DIR)/.config
	sed -i 's/^CONFIG_FEATURE_TC_INGRESS=y/# CONFIG_FEATURE_TC_INGRESS is not set/' $(BUSYBOX_DIR)/.config
	$(MAKE) -C $(BUSYBOX_DIR) -j$$(nproc)
	mkdir -p $(ROOTFS_DIR)
	$(MAKE) -C $(BUSYBOX_DIR) install CONFIG_PREFIX=$(abspath $(ROOTFS_DIR))

# Git
$(ROOTFS_DIR)/bin/git:
	./scripts/build_git.sh $(abspath $(ROOTFS_DIR))/bin

# Nushell
.PHONY: nushell-build
nushell-build:
	rustup target add x86_64-unknown-linux-musl
	cd $(NUSHELL_DIR) && CC_x86_64_unknown_linux_musl=musl-gcc cargo +stable build --release --target x86_64-unknown-linux-musl --features static-link-openssl --workspace

$(ROOTFS_DIR)/bin/nu: nushell-build
	mkdir -p $(ROOTFS_DIR)/bin
	cp -u $(NUSHELL_DIR)/target/x86_64-unknown-linux-musl/release/nu $(ROOTFS_DIR)/bin/nu
	@echo "Verifying Nushell binary..."
	file $(ROOTFS_DIR)/bin/nu

# Init System
.PHONY: init-build
init-build:
	cd $(INIT_DIR) && cargo +stable build --release --target x86_64-unknown-linux-musl

$(ROOTFS_DIR)/init: init-build
	cp -u $(INIT_DIR)/target/x86_64-unknown-linux-musl/release/init_system $(ROOTFS_DIR)/init

# Rootfs
$(BUILD_DIR)/initramfs.cpio.gz: $(ROOTFS_DIR)/bin/busybox $(ROOTFS_DIR)/bin/nu $(ROOTFS_DIR)/init $(ROOTFS_DIR)/bin/git
	mkdir -p $(ROOTFS_DIR)/proc $(ROOTFS_DIR)/sys $(ROOTFS_DIR)/dev $(ROOTFS_DIR)/tmp
	chmod +x $(ROOTFS_DIR)/init
	cd $(ROOTFS_DIR) && find . -print0 | cpio --null --create --format=newc | gzip --best > ../initramfs.cpio.gz

run:
	$(MAKE) $(BUILD_DIR)/bzImage
	$(MAKE) $(BUILD_DIR)/initramfs.cpio.gz
	qemu-system-x86_64 -kernel $(BUILD_DIR)/bzImage -initrd $(BUILD_DIR)/initramfs.cpio.gz -append "console=ttyS0" -nographic -netdev user,id=net0 -device virtio-net-pci,netdev=net0

clean:
	rm -rf $(BUILD_DIR)
