use std::process::Command;
use std::io::Write;

fn main() {
    println!("Welcome to NanoOS!");
    
    // Mount essential filesystems
    let _ = std::fs::create_dir_all("/proc");
    let _ = std::fs::create_dir_all("/sys");
    let _ = std::fs::create_dir_all("/dev");
    let _ = std::fs::create_dir_all("/tmp");
    
    let _ = Command::new("mount").args(&["-t", "proc", "proc", "/proc"]).status();
    let _ = Command::new("mount").args(&["-t", "sysfs", "sysfs", "/sys"]).status();
    let _ = Command::new("mount").args(&["-t", "devtmpfs", "dev", "/dev"]).status();

    println!("Launching Nushell...");
    
    // Launch Nushell directly
    let status = Command::new("/bin/nu")
        .status();

    if let Err(e) = status {
        println!("Failed to launch Nushell: {}", e);
        println!("Falling back to simple shell...");
        
        loop {
            print!("$ ");
            std::io::stdout().flush().unwrap();

            let mut input = String::new();
            std::io::stdin().read_line(&mut input).unwrap();

            println!("You said: {}", input.trim());
        }
    }
}
