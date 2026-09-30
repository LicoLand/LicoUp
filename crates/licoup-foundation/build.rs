//! Compiles the state-machine definitions this crate consumes.
//!
//! Only the machines whose runtime lives here are compiled; the JSON document
//! is the transition authority and moves with the module that reads it.

fn main() {
    let output = std::env::var_os("OUT_DIR")
        .map(std::path::PathBuf::from)
        .expect("OUT_DIR is set for build scripts")
        .join("state_machines.rs");
    licoup_state_machine_codegen::compile_file(
        "resources/state-machines/ansi-parser.json",
        &output,
    )
    .expect("foundation state-machine configuration must compile");
}
