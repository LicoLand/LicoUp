use crate::platform::file_security::ensure_private_dir;
use serde_json::json;

use super::support::TestRoot;

#[test]
fn bounded_private_json_round_trip_is_atomic() {
    let root = TestRoot::new("serialization");
    let state = root.path().join("state");
    ensure_private_dir(&state).unwrap();
    let path = state.join("document.json");
    super::super::serialization::atomic_write_json(&path, &json!({"ok": true}), 1024).unwrap();

    let document =
        super::super::serialization::read_json_or_default(&path, 1024, || json!({})).unwrap();
    assert_eq!(document["ok"], true);
    assert!(super::super::serialization::read_json_or_default(&path, 2, || json!({})).is_err());
}

#[test]
fn identifiers_and_hashes_are_deterministic_and_bounded() {
    assert_eq!(
        super::super::serialization::sanitize_id(" ../Open Code "),
        "Open-Code"
    );
    assert_eq!(super::super::serialization::sanitize_id("///"), "item");
    assert_eq!(
        super::super::serialization::sanitize_id(&"a".repeat(100)).len(),
        64
    );
    assert_eq!(
        super::super::serialization::hash_text("same"),
        super::super::serialization::hash_text("same")
    );
    assert_ne!(
        super::super::serialization::hash_text("same"),
        super::super::serialization::hash_text("different")
    );
}
