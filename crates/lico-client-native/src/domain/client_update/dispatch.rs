use anyhow::{Result, bail};
use serde_json::Value;

pub fn dispatch(args: &[String], params: &Value) -> Result<Value> {
    match args.get(1).map(String::as_str).unwrap_or("status") {
        "status" => super::status::status(params),
        "check" => super::check::check(params),
        "download" => super::download::download(params),
        "verify" => super::verify::verify(params),
        "apply" => super::apply::apply(params),
        "rollback" => super::apply::rollback(params),
        _ => bail!("client update command is unsupported"),
    }
}
