use base64::{Engine as _, engine::general_purpose};
use serde_json::{Value, json};

pub(super) fn native_envelope_fixture() -> Value {
    json!({
        "schema": crate::core::secure_mesh_relay_envelope::SECURE_MESH_RELAY_ENVELOPE_SCHEMA,
        "deliveryId": general_purpose::URL_SAFE_NO_PAD.encode([1u8; 24]),
        "mailboxToken": general_purpose::URL_SAFE_NO_PAD.encode([2u8; 32]),
        "encryptedHeader": general_purpose::URL_SAFE_NO_PAD.encode(vec![
            3u8;
            crate::core::secure_mesh_relay_envelope::SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES
        ]),
        "ciphertextBucket": 256,
        "ciphertext": general_purpose::URL_SAFE_NO_PAD.encode([4u8; 256])
    })
}
