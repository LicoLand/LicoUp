//! Endpoint delivery primitive checks.

use super::support::*;
use rand_core::OsRng;
use rand_core::RngCore;

#[test]
fn delivery_secret_and_channel_binding_keep_key_material_opaque() {
    let mut delivery_secret_bytes = [0u8; DELIVERY_SECRET_BYTES];
    OsRng.fill_bytes(&mut delivery_secret_bytes);
    let secret = SecureMeshDeliverySecret::from_bytes(delivery_secret_bytes);
    assert_eq!(secret.as_bytes(), &delivery_secret_bytes);
    assert_eq!(
        format!("{secret:?}"),
        "SecureMeshDeliverySecret([redacted])"
    );

    let binding = SecureMeshRelayChannelBinding::from_bytes([0x32; CHANNEL_BINDING_BYTES]);
    assert_eq!(binding.as_bytes(), &[0x32; CHANNEL_BINDING_BYTES]);
    assert_eq!(
        format!("{binding:?}"),
        "SecureMeshRelayChannelBinding([redacted])"
    );
}
