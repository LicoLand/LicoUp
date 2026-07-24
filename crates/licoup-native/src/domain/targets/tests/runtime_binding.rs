use super::super::available_runtime_executable;

#[test]
fn runtime_binding_rejects_unknown_targets() {
    assert!(available_runtime_executable("unknown-target").is_none());
}
