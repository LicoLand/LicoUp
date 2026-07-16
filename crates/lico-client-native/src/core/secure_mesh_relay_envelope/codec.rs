//! Bounded canonical base64url and length-prefixed field codec.

use anyhow::{Context, Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};

pub(in crate::core::secure_mesh_relay_envelope) fn append_len_prefixed(
    output: &mut Vec<u8>,
    value: &[u8],
) -> Result<()> {
    let length = u16::try_from(value.len())
        .map_err(|_| anyhow!("secure mesh mailbox derivation field is too large"))?;
    output.extend_from_slice(&length.to_be_bytes());
    output.extend_from_slice(value);
    Ok(())
}

pub(in crate::core::secure_mesh_relay_envelope) fn decode_exact_base64url(
    label: &str,
    value: &str,
    expected_bytes: usize,
) -> Result<Vec<u8>> {
    decode_bounded_base64url(label, value, expected_bytes, expected_bytes)
}

pub(in crate::core::secure_mesh_relay_envelope) fn decode_bounded_base64url(
    label: &str,
    value: &str,
    minimum_bytes: usize,
    maximum_bytes: usize,
) -> Result<Vec<u8>> {
    ensure!(
        minimum_bytes <= maximum_bytes,
        "secure mesh relay envelope decoder bounds are invalid"
    );
    let maximum_encoded_len = base64url_encoded_len(maximum_bytes)?;
    ensure!(
        !value.is_empty() && value.len() <= maximum_encoded_len,
        "secure mesh relay envelope {label} is outside encoded bounds"
    );
    let decoded = general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .with_context(|| format!("secure mesh relay envelope {label} is not base64url"))?;
    ensure!(
        (minimum_bytes..=maximum_bytes).contains(&decoded.len()),
        "secure mesh relay envelope {label} is outside decoded bounds"
    );
    ensure!(
        general_purpose::URL_SAFE_NO_PAD.encode(&decoded) == value,
        "secure mesh relay envelope {label} is not canonical base64url"
    );
    Ok(decoded)
}

pub(in crate::core::secure_mesh_relay_envelope) fn base64url_encoded_len(
    input_bytes: usize,
) -> Result<usize> {
    let complete = input_bytes
        .checked_div(3)
        .and_then(|groups| groups.checked_mul(4))
        .ok_or_else(|| anyhow!("secure mesh relay envelope encoded length overflow"))?;
    let remainder = match input_bytes % 3 {
        0 => 0,
        1 => 2,
        2 => 3,
        _ => unreachable!(),
    };
    complete
        .checked_add(remainder)
        .ok_or_else(|| anyhow!("secure mesh relay envelope encoded length overflow"))
}
