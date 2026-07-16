//! Length-safe constant-time equality for authenticated token candidates.

use subtle::ConstantTimeEq;

pub(in crate::core::secure_mesh_relay_envelope) fn constant_time_equal(
    left: &[u8],
    right: &[u8],
) -> bool {
    left.len() == right.len() && bool::from(left.ct_eq(right))
}
