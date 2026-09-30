//! Compiles the state-machine definitions this crate consumes.
//!
//! Only the machines whose runtime lives here are compiled; the JSON document
//! is the transition authority and moves with the module that reads it.

fn main() {
    println!("cargo:rerun-if-changed=resources/state-machines");
    licoup_state_machine_codegen::generate_directory("resources/state-machines")
        .expect("application state-machine configuration must compile");
}
