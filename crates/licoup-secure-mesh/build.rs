//! Compiles the state machines this crate owns. The ML-KEM Braid session's and
//! the group (MLS) operation ledger's transition tables live here; each moved
//! with the code that drives it, so the machine's configuration lives beside
//! that code.

fn main() {
    println!("cargo:rerun-if-changed=resources/state-machines");
    licoup_state_machine_codegen::generate_directory("resources/state-machines")
        .expect("secure-mesh state-machine configuration must compile");
}
