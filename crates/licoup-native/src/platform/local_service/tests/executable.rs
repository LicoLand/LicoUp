use super::super::executable;
use serde_json::json;

#[test]
fn explicit_executable_wins_and_missing_absolute_paths_fail_closed() {
    let resolved = executable::resolve(
        &json!({"executable": "/definitely/missing/local-agent"}),
        &[],
        "fallback",
    );
    assert_eq!(resolved, "/definitely/missing/local-agent");
    assert!(!executable::available(&resolved));
}
