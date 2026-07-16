use anyhow::{Result, anyhow, ensure};
use serde_json::Value;

pub(super) const MAX_FFI_REQUEST_BYTES: usize = 4 * 1024 * 1024;
pub(super) const MAX_FFI_JSON_DEPTH: usize = 64;
pub(super) const MAX_FFI_JSON_NODES: usize = 65_536;
pub(super) const MAX_FFI_OBJECT_FIELDS: usize = 1_024;
pub(super) const MAX_FFI_ARRAY_ITEMS: usize = 4_096;
pub(super) const MAX_FFI_STRING_BYTES: usize = 2 * 1024 * 1024;

pub(super) fn validate_ffi_request_bytes(request_json: &str) -> Result<()> {
    ensure!(
        request_json.len() <= MAX_FFI_REQUEST_BYTES,
        "secure mesh native request exceeds the byte limit"
    );
    Ok(())
}

pub(super) fn validate_ffi_json_structure(request: &Value) -> Result<()> {
    let mut stack = vec![(request, 1usize)];
    let mut nodes = 0usize;
    while let Some((value, depth)) = stack.pop() {
        ensure!(
            depth <= MAX_FFI_JSON_DEPTH,
            "secure mesh native request exceeds the JSON depth limit"
        );
        nodes = nodes
            .checked_add(1)
            .ok_or_else(|| anyhow!("secure mesh native request node count overflow"))?;
        ensure!(
            nodes <= MAX_FFI_JSON_NODES,
            "secure mesh native request exceeds the JSON node limit"
        );
        match value {
            Value::String(value) => ensure!(
                value.len() <= MAX_FFI_STRING_BYTES,
                "secure mesh native request contains an oversized string"
            ),
            Value::Array(values) => {
                ensure!(
                    values.len() <= MAX_FFI_ARRAY_ITEMS,
                    "secure mesh native request contains an oversized array"
                );
                for value in values.iter().rev() {
                    stack.push((value, depth.saturating_add(1)));
                }
            }
            Value::Object(values) => {
                ensure!(
                    values.len() <= MAX_FFI_OBJECT_FIELDS,
                    "secure mesh native request contains an oversized object"
                );
                for (key, value) in values.iter().rev() {
                    ensure!(
                        key.len() <= MAX_FFI_STRING_BYTES,
                        "secure mesh native request contains an oversized object key"
                    );
                    stack.push((value, depth.saturating_add(1)));
                }
            }
            Value::Null | Value::Bool(_) | Value::Number(_) => {}
        }
    }
    Ok(())
}
