//! Compiles the state machines this crate owns. The durable endpoint storage's
//! custody lifecycle is the machine this crate drives, so the machine's
//! configuration lives beside the code that drives it.

fn main() {
    println!("cargo:rerun-if-changed=resources/state-machines");
    licoup_state_machine_codegen::generate_directory("resources/state-machines")
        .expect("relay state-machine configuration must compile");
}
