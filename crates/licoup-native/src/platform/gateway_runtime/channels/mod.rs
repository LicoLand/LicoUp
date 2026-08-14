//! Communication Channel layer of the Gateway Runtime.

pub mod telegram;

use anyhow::Result;
use serde_json::{Value, json};

pub fn channel_layer_status() -> Result<Value> {
    let telegram = telegram::channel_status()?;
    Ok(json!({
        "ok": true,
        "schemaVersion": "licoup.gateway-channels.v1",
        "layer": "communication-channel",
        "channels": {
            "telegram": telegram,
        }
    }))
}
