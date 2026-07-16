use super::{CliExecution, CommandTable, cli_params};
use anyhow::{Result, anyhow, ensure};
use serde_json::Value;
use std::io::Read;

const MAX_PRIVATE_CATALOG_REQUEST_BYTES: usize = 4 * 1024 * 1024;

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(
        &["catalog"],
        handle_catalog,
        "Catalog convergence status|invalidate|refresh|receipt|purge|reconnect",
    );
}

fn handle_catalog(args: &[String]) -> Result<CliExecution> {
    let control = cli_params(args.get(2..).unwrap_or_default());
    let params = if control.get("stdinJson").and_then(bool_param) == Some(true) {
        private_stdin_params()?
    } else {
        control
    };
    Ok(CliExecution::Json(
        crate::domain::catalog_convergence::dispatch(args, &params)?,
    ))
}

fn private_stdin_params() -> Result<Value> {
    let mut bytes = Vec::new();
    std::io::stdin()
        .take((MAX_PRIVATE_CATALOG_REQUEST_BYTES as u64).saturating_add(1))
        .read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= MAX_PRIVATE_CATALOG_REQUEST_BYTES,
        "catalog_private_input_too_large"
    );
    let params: Value =
        serde_json::from_slice(&bytes).map_err(|_| anyhow!("catalog_private_input_invalid"))?;
    ensure!(params.is_object(), "catalog_private_input_invalid");
    Ok(params)
}

fn bool_param(value: &Value) -> Option<bool> {
    value.as_bool().or_else(|| match value.as_str() {
        Some("true") => Some(true),
        Some("false") => Some(false),
        _ => None,
    })
}
