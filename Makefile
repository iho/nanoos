KERNEL_DIR = linux
BUSYBOX_DIR = busybox
INIT_DIR = init_system
NUSHELL_DIR = nushell
ZEN_DIR = zen
ALACRITTY_DIR = alacritty
BUILD_DIR = build
ROOTFS_DIR = $(BUILD_DIR)/rootfs
PYTHON_STDLIB_DIR := $(firstword $(wildcard $(BUILD_DIR)/sysroot/lib/python3.*))
PYTHON_VERSION := $(subst python,,$(notdir $(PYTHON_STDLIB_DIR)))

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
	$(KERNEL_DIR)/scripts/config --file $(KERNEL_DIR)/.config --enable CONFIG_DRM_BOCHS
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

# Zen (Wayland Compositor)
.PHONY: zen-build
zen-build:
	cd $(ZEN_DIR) && \
		export PATH="$(abspath $(BUILD_DIR)/toolchain/x86_64-linux-musl-cross/bin):$$PATH" && \
		export CC_x86_64_unknown_linux_musl=x86_64-linux-musl-gcc && \
		export CXX_x86_64_unknown_linux_musl=x86_64-linux-musl-g++ && \
		export PKG_CONFIG_PATH=$(abspath $(BUILD_DIR)/sysroot/lib/pkgconfig):$(abspath $(BUILD_DIR)/sysroot/lib64/pkgconfig):$(abspath $(BUILD_DIR)/sysroot/share/pkgconfig) && \
		export PKG_CONFIG_ALLOW_CROSS=1 && \
		export PKG_CONFIG_SYSROOT_DIR=$(abspath $(BUILD_DIR)/sysroot) && \
		export LIBSEAT_STATIC=1 && \
		export LIBINPUT_STATIC=1 && \
		export PYO3_CROSS_PYTHON_VERSION=$(PYTHON_VERSION) && \
		export PYO3_CROSS_LIB_DIR=$(abspath $(BUILD_DIR)/sysroot/lib) && \
		export RUSTFLAGS="-L $(abspath $(BUILD_DIR)/toolchain/x86_64-linux-musl-cross/x86_64-linux-musl/lib) -L $(abspath $(BUILD_DIR)/sysroot/lib) -L $(abspath $(BUILD_DIR)/sysroot/lib64) -C link-arg=-lgcc -C link-arg=-lgbm -C link-arg=-linput -C link-arg=-levdev -C link-arg=-lmtdev -C link-arg=-ludev -C link-arg=-lseat -C link-arg=-lwayland-server -C link-arg=-lwayland-client -C link-arg=-lxkbcommon -C link-arg=-lpixman-1 -C link-arg=-lffi -C link-arg=-lxml2 -C link-arg=-lz -C link-arg=-lexpat -C link-arg=-ldrm -C link-arg=-lm -C link-arg=-lrt -C link-arg=-lpthread -C link-arg=-lpython$(PYTHON_VERSION) -C link-arg=-lutil" && \
		cargo +stable build --release --target x86_64-unknown-linux-musl

$(ROOTFS_DIR)/bin/zen: zen-build
	mkdir -p $(ROOTFS_DIR)/bin
	cp -u $(ZEN_DIR)/target/x86_64-unknown-linux-musl/release/zen $(ROOTFS_DIR)/bin/zen
	cp -u $(ZEN_DIR)/config.py $(ROOTFS_DIR)/bin/config.py

.PHONY: alacritty-build
alacritty-build:
	rustup target add x86_64-unknown-linux-musl
	cd $(ALACRITTY_DIR) && \
		PKG_CONFIG_PATH=$(abspath $(BUILD_DIR))/sysroot/lib/pkgconfig:$(abspath $(BUILD_DIR))/sysroot/lib64/pkgconfig:$(abspath $(BUILD_DIR))/sysroot/share/pkgconfig \
		PKG_CONFIG_SYSROOT_DIR=$(abspath $(BUILD_DIR))/sysroot \
		PKG_CONFIG_ALL_STATIC=1 \
		PKG_CONFIG_ALLOW_CROSS=1 \
		CC_x86_64_unknown_linux_musl=musl-gcc \
		LIBRARY_PATH=$(abspath $(BUILD_DIR))/sysroot/lib:$(abspath $(BUILD_DIR))/sysroot/lib64 \
		RUSTFLAGS="-L $(abspath $(BUILD_DIR))/sysroot/lib -L $(abspath $(BUILD_DIR))/sysroot/lib64" \
		cargo +stable build --release --target x86_64-unknown-linux-musl

$(ROOTFS_DIR)/bin/alacritty: alacritty-build
	mkdir -p $(ROOTFS_DIR)/bin
	cp -u $(ALACRITTY_DIR)/target/x86_64-unknown-linux-musl/release/alacritty $(ROOTFS_DIR)/bin/alacritty

# Init System
.PHONY: init-build
init-build:
	cd $(INIT_DIR) && cargo +stable build --release --target x86_64-unknown-linux-musl

$(ROOTFS_DIR)/init: init-build
	cp -u $(INIT_DIR)/target/x86_64-unknown-linux-musl/release/init_system $(ROOTFS_DIR)/init

# Rootfs
$(BUILD_DIR)/initramfs.cpio.gz: $(ROOTFS_DIR)/bin/busybox $(ROOTFS_DIR)/bin/nu $(ROOTFS_DIR)/init $(ROOTFS_DIR)/bin/git $(ROOTFS_DIR)/bin/zen $(ROOTFS_DIR)/bin/alacritty
	mkdir -p $(ROOTFS_DIR)/proc $(ROOTFS_DIR)/sys $(ROOTFS_DIR)/dev $(ROOTFS_DIR)/tmp
	# Include Python stdlib so embedded Python in zen can import encodings and other modules
	@if [ -d "$(PYTHON_STDLIB_DIR)" ]; then \
		mkdir -p $(ROOTFS_DIR)/lib; \
		cp -a $(PYTHON_STDLIB_DIR) $(ROOTFS_DIR)/lib/; \
	else \
		echo "Python stdlib not found in $(BUILD_DIR)/sysroot/lib (expected python3.*)"; \
		exit 1; \
	fi
	# Copy XKB data for xkbcommon so keyboard layouts load correctly
	@if [ -d "$(BUILD_DIR)/sysroot/share/X11/xkb" ]; then \
		src_dir=$(BUILD_DIR)/sysroot/share/X11/xkb; \
	elif [ -d "/usr/share/X11/xkb" ]; then \
		src_dir=/usr/share/X11/xkb; \
	else \
		echo "XKB data not found in sysroot or host /usr/share/X11/xkb"; \
		exit 1; \
	fi; \
	mkdir -p $(ROOTFS_DIR)/share/X11; \
	rsync -a --delete $$src_dir $(ROOTFS_DIR)/share/X11/
	chmod +x $(ROOTFS_DIR)/init
	cd $(ROOTFS_DIR) && find . -print0 | cpio --null --create --format=newc | gzip --best > ../initramfs.cpio.gz

run:
	$(MAKE) $(BUILD_DIR)/bzImage
	$(MAKE) $(BUILD_DIR)/initramfs.cpio.gz
	qemu-system-x86_64 -kernel $(BUILD_DIR)/bzImage -initrd $(BUILD_DIR)/initramfs.cpio.gz -append "console=ttyS0" -serial stdio -vga std -display sdl -netdev user,id=net0 -device virtio-net-pci,netdev=net0 -m 2048 -smp 2

clean:
	rm -rf $(BUILD_DIR)
