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
fn latest_items_obey_exact_pretty_json_bytes_and_count() {
    use super::super::serialization::retain_latest_items;
    use serde_json::Value;

    let document = json!({
        "schemaVersion": "synthetic",
        "metadata": {"label": "外层\n\\\"", "nested": [1, {}]},
        "items": [null, true, "彩虹\n\\\"", [], {}, {"nested": [{"value": "🌈"}, 12.5]}]
    });
    let items = document["items"].as_array().unwrap();
    for count in 1..=items.len() {
        let mut expected = document.clone();
        expected["items"] = Value::Array(items[items.len() - count..].to_vec());
        let exact_bytes = serde_json::to_vec_pretty(&expected).unwrap().len() + 1;
        let mut actual = document.clone();
        retain_latest_items(&mut actual, items.len(), exact_bytes).unwrap();
        assert_eq!(actual, expected);

        let mut below = document.clone();
        let result = retain_latest_items(&mut below, items.len(), exact_bytes - 1);
        if count == 1 {
            assert!(result.is_err());
        } else {
            result.unwrap();
            expected["items"] = Value::Array(items[items.len() - count + 1..].to_vec());
            assert_eq!(below, expected);
        }
    }
    let mut limited = document.clone();
    retain_latest_items(&mut limited, 2, usize::MAX).unwrap();
    assert_eq!(limited["items"], json!(items[items.len() - 2..]));

    let mut empty = json!({"items": [], "metadata": "preserved"});
    let exact_bytes = serde_json::to_vec_pretty(&empty).unwrap().len() + 1;
    retain_latest_items(&mut empty, 2, exact_bytes).unwrap();
    assert_eq!(empty, json!({"items": [], "metadata": "preserved"}));
    assert!(retain_latest_items(&mut empty, 2, exact_bytes - 1).is_err());
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
