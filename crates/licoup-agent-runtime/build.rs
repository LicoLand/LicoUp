fn main() {
    licoup_state_machine_codegen::generate_directory("resources/state-machines")
        .expect("valid Agent runtime state machines");
}
