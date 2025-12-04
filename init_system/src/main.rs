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

    println!("Filesystems mounted.");
    
    loop {
        println!("Launching Nushell via cttyhack...");

        // Use busybox setsid + cttyhack to set up the controlling terminal properly
        let status = Command::new("/bin/busybox")
            .arg("setsid")
            .arg("cttyhack")
            .env("TERM", "linux")
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
