use std::io::Write;

fn main() {
    loop {
        print!("$ ");
        std::io::stdout().flush().unwrap();

        let mut input = String::new();
        std::io::stdin().read_line(&mut input).unwrap();

        println!("Sorry, I don't know how to do that.");
    }
}
