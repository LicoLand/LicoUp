use super::super::delivery::relay_envelope_from_delivery;
use serde_json::json;

#[test]
fn delivery_conversion_requires_every_canonical_outer_field() {
    let error = relay_envelope_from_delivery(&json!({"deliveryId": "only-one-field"}))
        .err()
        .expect("incomplete delivery must be rejected");
    assert!(error.to_string().contains("envelope is incomplete"));
}
