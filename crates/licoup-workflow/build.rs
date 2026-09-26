fn main() {
    println!("cargo:rerun-if-changed=resources/state-machines");
    licoup_state_machine_codegen::generate_directory("resources/state-machines")
        .expect("compile workflow state machines");
}
