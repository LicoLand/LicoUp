use super::super::ready_runtime_executable;

#[test]
fn runtime_binding_rejects_unknown_or_unready_targets() {
    assert!(ready_runtime_executable("unknown-target").is_none());
}
