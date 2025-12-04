use std::process::Command;
use std::io::Write;

fn main() {
    println!("NanoOS Init Starting...");

    // Mount filesystems using busybox mount since we don't have libc bindings directly here easily
    // and we know busybox is in /bin
    let _ = std::fs::create_dir_all("/proc");
    let _ = std::fs::create_dir_all("/sys");
    let _ = std::fs::create_dir_all("/dev");

    // We need to specify the full path to busybox or assume it's in the path. 
    // In our rootfs structure, busybox is in /bin/busybox and symlinked.
    // Let's try to run the mount commands.
    let _ = Command::new("/bin/mount").args(&["-t", "proc", "proc", "/proc"]).status();
    let _ = Command::new("/bin/mount").args(&["-t", "sysfs", "sysfs", "/sys"]).status();
    
    // devtmpfs is crucial for populating /dev
    let _ = Command::new("/bin/mount").args(&["-t", "devtmpfs", "dev", "/dev"]).status();

    // Mount devpts for PTY support (needed by some shells/editors)
    let _ = std::fs::create_dir_all("/dev/pts");
    let _ = Command::new("/bin/mount").args(&["-t", "devpts", "devpts", "/dev/pts"]).status();

    // Network Setup
    println!("Setting up network...");
    
    // List PCI devices to debug what hardware the kernel sees
    let _ = Command::new("/bin/busybox").args(&["lspci", "-k"]).status();

    // List interfaces for debugging
    let _ = Command::new("/bin/busybox").args(&["ip", "link"]).status();

    // Loopback
    let _ = Command::new("/bin/busybox").args(&["ip", "link", "set", "lo", "up"]).status();
    
    // eth0 (QEMU User Net usually provides this)
    // We try to bring it up. If it's named differently (e.g. enp0s3), this might fail, 
    // but ip link above will tell us.
    let _ = Command::new("/bin/busybox").args(&["ip", "link", "set", "eth0", "up"]).status();
    let _ = Command::new("/bin/busybox").args(&["ip", "addr", "add", "10.0.2.15/24", "dev", "eth0"]).status();
    let _ = Command::new("/bin/busybox").args(&["ip", "route", "add", "default", "via", "10.0.2.2"]).status();
    
    // DNS
    let _ = std::fs::create_dir_all("/etc");
    let _ = std::fs::write("/etc/resolv.conf", "nameserver 1.1.1.1\n");

    println!("Filesystems mounted. Network configured.");
    
    loop {
        println!("Launching Nushell via cttyhack...");

        // Attempt to sanitize terminal before launch
        let _ = Command::new("/bin/busybox").args(&["stty", "sane"]).status();

        // Use busybox setsid + cttyhack to set up the controlling terminal properly
        let status = Command::new("/bin/busybox")
            .arg("setsid")
            .arg("cttyhack")
            .env("TERM", "linux")
            .env("PATH", "/bin:/usr/bin")
            .arg("/bin/nu")
            .status();

        println!("Nushell exited with: {:?}", status);
        println!("Falling back to BusyBox shell...");
        
        let _ = Command::new("/bin/busybox")
            .arg("setsid")
            .arg("cttyhack")
            .arg("/bin/sh")
            .status();
            
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
}
